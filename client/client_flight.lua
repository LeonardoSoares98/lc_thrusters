-- Flight computer: fires the lift (underbody corners) and side thrusters (front). Holding the key climbs at a steady speed. Falling, the car
-- falls freely until the last moment it can still stop, then the lift brakes it to a soft touchdown. In the air, stability control keeps
-- the car level and pointing where it travels, and A/D (roll) and W/S (pitch) turn it with the thrusters for stunts. Every push comes from
-- a nozzle (client_thrusters.lua), so the car only moves the way its thrusters can push it: tilted it drifts, upside down it falls while
-- the thrusters roll it back

-- Do not load anything here if the flight computer is disabled
if not Config.Flight.enabled then
    return
end

isFlying = false            -- The flight computer runs (read by the suction fan, which stays off meanwhile)

local INPUT_VEH_MOVE_LR = 59
local INPUT_VEH_MOVE_UD = 60
local INPUT_VEH_ACCELERATE = 71
local INPUT_VEH_BRAKE = 72
local INPUT_VEH_HANDBRAKE = 76
local GRAVITY = 9.77                -- Measured on vehicles in free fall
local MIN_TRAVEL_SPEED = 5.0        -- m/s of horizontal speed from which the nose follows the direction of travel
local MIN_INPUT = 0.1               -- Stick/key input below this is ignored
local WORLD_UP = vector3(0.0, 0.0, 1.0)
local MIN_PROBE_RANGE = 20.0           -- m
local MAX_PROBE_RANGE = 500.0
local PROBE_INTERVAL = 50              -- ms between ground probes while falling, the height is estimated from the fall speed in between
local STUNT_CONTROLS = { INPUT_VEH_MOVE_LR, INPUT_VEH_ACCELERATE, INPUT_VEH_BRAKE }

-- Flight computer tuning
local HOLD_RESPONSIVENESS = 2.0     -- How hard the lift corrects the vertical speed
local MIN_UPRIGHT_FOR_LIFT = 0.7    -- The lift works only while the car's up direction points this much up (1 = level, 0 = on its side):
                                    -- tilted more, most of its push would go sideways and shove the car off its line
local TOUCHDOWN_SPEED = 1.5         -- m/s of fall at touchdown with the landing assist
local LANDING_MARGIN = 0.8          -- Share of the lift the landing burn plans on, the rest is reserve for levelling and errors (0..1)
local LANDING_SAFETY = 1.5          -- m added to the braking distance before the landing burn starts
local BURN_RELEASE_MARGIN = 2.0     -- m above the burn's start height at which a burn lets go again (the ground dropped away under the car)
local STUNT_MIN_AIR_TIME = 300      -- ms in the air before A/D and W/S do stunts. Keys held at take-off count only after being pressed again
local STUNT_RECOVERY_DELAY = 500    -- ms after letting go of A/D and W/S before levelling, heading and landing assist come back
local ATTITUDE_GAIN = 1.5           -- Throttle per radian of roll or pitch away from level
local ATTITUDE_DAMPING = 0.5        -- Throttle per rad/s of roll or pitch speed (stops the car from overshooting level)
local HEADING_GAIN = 1.0            -- Throttle per radian of the nose away from the direction of travel
local YAW_DAMPING = 0.4             -- Throttle per rad/s of the car spinning flat
local ROLL_RATE = 5.0               -- rad/s of roll asked with A/D (a full kickflip in about 1.3 s)
local PITCH_RATE = 3.5              -- rad/s of pitch asked with W/S
local RATE_GAIN = 0.6               -- Throttle per rad/s of difference from the asked roll or pitch speed

local isLiftKeyDown = false
local climbTimeUsed = 0     -- ms of climbing since the vehicle last touched the ground (lift key, or the boost pushing upwards)

-- Nozzles the flight computer drives, and the most the lift nozzles can push together (m/s² along the car's up direction)
local flightNozzles = {}
local maxLift = 0.0
for index, nozzle in ipairs(NOZZLES) do
    if nozzle.group == "lift" or nozzle.group == "side" then
        flightNozzles[#flightNozzles + 1] = index
    end
    if nozzle.group == "lift" then
        maxLift = maxLift + nozzle.maxAcceleration * math.max(0.0, -nozzle.exhaust.z)
    end
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Threads
-----------------------------------------------------------------------------------------------------------------------------------------

-- Starts the flight computer when the vehicle leaves the ground by itself (a jump, a ramp), for the assists the driver has on (stability
-- control, landing assist, stunts). It must be in the air for two checks in a row, so a bump in the road doesn't fire the thrusters
function createFlightMonitorThread()
    CreateThread(function()
        local airborneChecks = 0
        while true do
            -- Not while the fan holds the car on a surface right under it: on a loop the tyres barely touch, but the car isn't flying
            local anyAssist = isAssistOn("stabilityControl") or isAssistOn("landingAssist") or isAssistOn("stunts")
            if anyAssist and currentVehicle ~= 0 and not isFlying and not suctionHolding and IsEntityInAir(currentVehicle) then
                airborneChecks = airborneChecks + 1
                if airborneChecks >= 2 then
                    createFlightThread(currentVehicle)
                    airborneChecks = 0
                end
            else
                airborneChecks = 0
            end
            Wait(50)
        end
    end)
end

-- Runs every frame while the vehicle is in the air or the lift key is held
function createFlightThread(vehicle)
    CreateThread(function()
        isFlying = true
        local ped = PlayerPedId()
        local flight = {
            axes = nil,             -- Car axes of the last frame, for its turn speeds
            heldHeading = nil,      -- Direction the nose keeps while slow
            landingBurn = false,    -- The landing braking is on (re-checked every frame)
            probe = nil,            -- Last ground probe: { at = time, height = height or false }
            wasInAir = false,
            airSince = GetGameTimer(),  -- When the car last left the ground
            blocked = {},           -- [control] = true while a key held at take-off wasn't released yet
            lastStuntInput = -1e9,  -- When the player last turned the car with A/D or W/S
            liftUsed = false,       -- The lift key was used in this flight: the car is kept level even with stability control off
        }

        while currentVehicle == vehicle and DoesEntityExist(vehicle) and GetPedInVehicleSeat(vehicle, -1) == ped do
            local inAir = IsEntityInAir(vehicle)
            if not inAir then
                -- On the ground: the next flight gets its full climb time and picks its own heading
                resetClimbTime()
                flight.heldHeading = nil
                if not isLiftKeyDown then
                    break   -- Landed
                end
            end
            local dt = math.max(GetFrameTime(), 0.001)
            if isLiftKeyDown then
                DisableControlAction(0, INPUT_VEH_HANDBRAKE, true)
            end
            if inAir and isAssistOn("stunts") then
                DisableControlAction(0, INPUT_VEH_MOVE_LR, true)
                DisableControlAction(0, INPUT_VEH_MOVE_UD, true)
            end

            -- The player's part (climb, stunts) is only computed while above the reserve, so the rest are assists and may use it
            local throttles, lift = computeFlightThrottles(vehicle, dt, inAir, flight)
            if not fireNozzles(vehicle, throttles, dt, true, lift) then
                stopNozzleGroup("lift")     -- Tank empty (the readout shows it)
                stopNozzleGroup("side")
            end
            Wait(0)
        end

        stopNozzleGroup("lift")
        stopNozzleGroup("side")
        isFlying = false
    end)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Functions
-----------------------------------------------------------------------------------------------------------------------------------------

function createFlightKeybind()
    RegisterCommand('+lc_thrusters_lift', startLift, false)
    RegisterCommand('-lc_thrusters_lift', function()
        isLiftKeyDown = false
    end, false)
    RegisterKeyMapping('+lc_thrusters_lift', Utils.translate('keybind_lift'), 'keyboard', Config.Flight.key)
end

function startLift()
    isLiftKeyDown = true
    if isFlying or currentVehicle == 0 or IsPauseMenuActive() then
        return
    end
    createFlightThread(currentVehicle)
end

-- Throttle of each lift and side nozzle for this frame
function computeFlightThrottles(vehicle, dt, inAir, flight)
    local forward = GetEntityForwardVector(vehicle)
    local _, _, up = GetEntityMatrix(vehicle)
    local right = cross(forward, up)

    -- Turn speeds in the car's frame, from how its axes moved since the last frame. x: nose up, y: right side down, z: nose left.
    -- These work in any position, upside down included
    local spin = vector3(0.0, 0.0, 0.0)
    if flight.axes then
        spin = vector3(dot(forward, flight.axes.up), dot(up, flight.axes.right), dot(right, flight.axes.forward)) / dt
    end
    flight.axes = { right = right, forward = forward, up = up }

    -- Stunts: while the player turns the car, and for STUNT_RECOVERY_DELAY after, the assists (levelling, heading, landing) stop so they
    -- don't fight the trick. Only the turns asked are driven, the other axes are just damped
    updateStuntInputs(flight, inAir)
    local rollInput, pitchInput = 0.0, 0.0
    if inAir and isAssistOn("stunts") then
        rollInput = getStuntInput(flight, INPUT_VEH_MOVE_LR)                                                -- D: right side down
        pitchInput = getStuntInput(flight, INPUT_VEH_BRAKE) - getStuntInput(flight, INPUT_VEH_ACCELERATE)  -- S: nose up
        if math.abs(rollInput) > MIN_INPUT or math.abs(pitchInput) > MIN_INPUT then
            if hasPlayerGas() then
                flight.lastStuntInput = GetGameTimer()
            else
                rollInput, pitchInput = 0.0, 0.0     -- Tank at the assist reserve
            end
        end
    end
    local stunting = inAir and GetGameTimer() - flight.lastStuntInput < STUNT_RECOVERY_DELAY

    -- Levelling and heading: stability control, or always in a flight the driver started with the lift key
    if isLiftKeyDown then
        flight.liftUsed = true
    end
    local stabilizing = isAssistOn("stabilityControl") or flight.liftUsed

    -- Vertical: climb while the key is held (and the climb time lasts), otherwise land
    local liftThrottle = 0.0
    if isLiftKeyDown and hasClimbTime() and hasPlayerGas() then
        flight.landingBurn = false
        if inAir then
            useClimbTime(dt * 1000)
        end
        liftThrottle = getLiftThrottle(vehicle, up, Config.Flight.climbSpeed)
    elseif stunting then
        flight.landingBurn = false      -- Planned again once the stunt is over
    elseif inAir and isAssistOn("landingAssist") then
        liftThrottle = getLandingThrottle(vehicle, up, flight, stabilizing)
    end

    -- Turning: only in the air, on the ground the wheels hold the car
    local pitchCommand, rollCommand, yawCommand = 0.0, 0.0, 0.0
    if inAir then
        pitchCommand, rollCommand = getAttitudeCommands(forward, right, up, spin, rollInput, pitchInput, stunting, stabilizing)
        if stabilizing then
            yawCommand = getHeadingCommand(vehicle, forward, up, spin, flight, stunting)
        end
    end

    return mixFlightThrottles(vehicle, liftThrottle, pitchCommand, rollCommand, yawCommand)
end

-- Climb time is shared by the lift key and the boost pushing upwards in the air, so pointing the car up and boosting can't climb
-- higher than the lift could
function hasClimbTime()
    return climbTimeUsed < Config.Flight.maxClimbTime
end

function useClimbTime(ms)
    climbTimeUsed = climbTimeUsed + ms
end

-- The lift key is held (read by the suction fan, which lets go while the car climbs)
function isLiftHeld()
    return isLiftKeyDown
end

-- Share of the climb time left (for the readout)
function getClimbRemaining()
    return math.max(0.0, 1.0 - climbTimeUsed / Config.Flight.maxClimbTime)
end

function resetClimbTime()
    climbTimeUsed = 0
end

-- Shared lift throttle that brings the vertical speed to targetSpeed. The lift pushes along the car's up direction, so tilted it needs
-- more throttle for the same vertical push, and past MIN_UPRIGHT_FOR_LIFT it stops (it would push the car sideways or down)
function getLiftThrottle(vehicle, up, targetSpeed)
    if up.z < MIN_UPRIGHT_FOR_LIFT or maxLift <= 0 then
        return 0.0
    end
    local wanted = (GRAVITY + (targetSpeed - GetEntityVelocity(vehicle).z) * HOLD_RESPONSIVENESS) / up.z
    return clamp(wanted / maxLift, 0.0, 1.0)
end

-- Landing with the least gas (a "suicide burn", like a rocket landing): the car falls freely while it is still high enough to stop, and
-- the burn starts when the height left is the braking distance at LANDING_MARGIN of the lift (+ LANDING_SAFETY). From then on the lift
-- brakes exactly enough to reach TOUCHDOWN_SPEED at the ground. Burning late is what saves gas: every second spent hovering on the way
-- down costs gas only to fight gravity.
-- The braking is planned with the car level when stability control levels it (it is, well before touchdown): planning with a tilt of the
-- moment started the burn far too high. And the burn is re-checked every frame: when the ground drops away under the car (it passed a
-- roof, a bridge or a hill) the burn lets go and the car falls freely again until the new last moment
function getLandingThrottle(vehicle, up, flight, stabilizing)
    if maxLift <= 0 or up.z < MIN_UPRIGHT_FOR_LIFT then
        return 0.0
    end
    local fallSpeed = -GetEntityVelocity(vehicle).z
    if not flight.landingBurn and fallSpeed <= TOUCHDOWN_SPEED then
        return 0.0      -- Rising or falling slowly: nothing to brake
    end

    -- Braking the lift can plan on (tilted it pushes less upwards). With none to spare it can't land the car
    local plannedUp = stabilizing and 1.0 or up.z
    local braking = maxLift * LANDING_MARGIN * plannedUp - GRAVITY
    if braking <= 0 then
        return 0.0
    end
    local stoppingDistance = math.max(0.0, fallSpeed ^ 2 - TOUCHDOWN_SPEED ^ 2) / (2 * braking)
    local height = getProbedHeight(vehicle, stoppingDistance + LANDING_SAFETY + BURN_RELEASE_MARGIN + MIN_PROBE_RANGE, fallSpeed, flight)
    if not height then
        flight.landingBurn = false
        return 0.0      -- No ground within range: still far, keep falling
    end

    -- Burning while within the braking distance. A burn lets go only BURN_RELEASE_MARGIN higher than it starts, so it doesn't flicker on
    -- and off (during a burn the height left stays within LANDING_SAFETY of the braking distance)
    local startHeight = stoppingDistance + LANDING_SAFETY
    if flight.landingBurn then
        if height > startHeight + BURN_RELEASE_MARGIN then
            flight.landingBurn = false
            return 0.0  -- The ground dropped away: free fall again
        end
    elseif height > startHeight then
        return 0.0      -- Free fall
    else
        flight.landingBurn = true
    end

    if fallSpeed <= TOUCHDOWN_SPEED then
        return getLiftThrottle(vehicle, up, -TOUCHDOWN_SPEED)    -- Slow enough: keep this speed down to the ground
    end
    -- Braking needed to lose the extra speed over the height left
    local needed = (fallSpeed ^ 2 - TOUCHDOWN_SPEED ^ 2) / (2 * math.max(height, 0.3))
    return clamp((GRAVITY + needed) / (maxLift * up.z), 0.0, 1.0)
end

-- Height above the ground, probed every PROBE_INTERVAL and estimated from the fall speed in between, or nil if no ground within range
function getProbedHeight(vehicle, range, fallSpeed, flight)
    local now = GetGameTimer()
    local probe = flight.probe
    if not probe or now - probe.at >= PROBE_INTERVAL then
        probe = { at = now, height = getHeightAboveGround(vehicle, range) or false }
        flight.probe = probe
    end
    if not probe.height then
        return nil
    end
    return probe.height - fallSpeed * (now - probe.at) / 1000
end

-- Height of the vehicle's bottom above whatever is under it (map, vehicles, objects), or nil if nothing within range
function getHeightAboveGround(vehicle, range)
    local distance = getGroundDistance(vehicle, clamp(range, MIN_PROBE_RANGE, MAX_PROBE_RANGE))
    if not distance then
        return nil
    end
    local min = GetModelDimensions(GetEntityModel(vehicle))
    return distance + min.z
end

-- Pitch and roll wanted: the player's A/D and W/S ask for a turn speed. Otherwise, with stabilizing, the car goes back to level, and during
-- a stunt its turn is only damped. Without stabilizing and outside a stunt the thrusters leave the car's turn alone
function getAttitudeCommands(forward, right, up, spin, rollInput, pitchInput, stunting, stabilizing)
    local pitchCommand, rollCommand = 0.0, 0.0
    if stunting or stabilizing then
        pitchCommand = -ATTITUDE_DAMPING * spin.x
        rollCommand = -ATTITUDE_DAMPING * spin.y
    end
    if stabilizing and not stunting then
        local angle = math.acos(clamp(up.z, -1.0, 1.0))
        if up.z < 0 then
            -- Past sideways: roll back over around the nose, like the real car after the ramp, and only keep the nose level with pitch.
            -- The shortest turn back to level is often a pitch here (the car leaves a half loop still pitching), which would flip it end
            -- over end. Rolling the way that lifts the car's up direction first: right.z > 0 means a positive roll does
            local rollDirection = right.z >= 0 and 1.0 or -1.0
            rollCommand = rollCommand + ATTITUDE_GAIN * rollDirection * angle
            pitchCommand = pitchCommand + ATTITUDE_GAIN * math.asin(clamp(forward.z, -1.0, 1.0))     -- Upside down, a positive pitch lowers the nose
        else
            -- Rotation that brings the car's up direction back to the world's, in the car's frame (the shortest turn back to level)
            local axis = cross(up, WORLD_UP)
            if #axis > 0.05 then
                axis = axis / #axis
            else
                axis = forward * -1.0
            end
            pitchCommand = pitchCommand + ATTITUDE_GAIN * dot(axis, right) * angle
            rollCommand = rollCommand + ATTITUDE_GAIN * dot(axis, forward) * angle
        end
    end

    if math.abs(rollInput) > MIN_INPUT then
        rollCommand = RATE_GAIN * (rollInput * ROLL_RATE - spin.y)
    end
    if math.abs(pitchInput) > MIN_INPUT then
        pitchCommand = RATE_GAIN * (pitchInput * PITCH_RATE - spin.x)
    end
    return pitchCommand, rollCommand
end

-- A key held when the car left the ground (accelerating, steering) is ignored until it's released, and stunt input waits for
-- STUNT_MIN_AIR_TIME in the air, so driving over a bump never flips the car. To do a stunt, press the key again in the air
function updateStuntInputs(flight, inAir)
    if inAir and not flight.wasInAir then
        flight.airSince = GetGameTimer()
        for _, control in ipairs(STUNT_CONTROLS) do
            flight.blocked[control] = isControlHeld(control)
        end
    end
    flight.wasInAir = inAir
    for control, blocked in pairs(flight.blocked) do
        if blocked and not isControlHeld(control) then
            flight.blocked[control] = false
        end
    end
end

function getStuntInput(flight, control)
    if flight.blocked[control] or GetGameTimer() - flight.airSince < STUNT_MIN_AIR_TIME then
        return 0.0
    end
    return GetDisabledControlNormal(0, control)
end

function isControlHeld(control)
    return math.abs(GetDisabledControlNormal(0, control)) > MIN_INPUT
end

-- Yaw wanted: the nose follows the direction of travel (backwards when the car flies backwards), or keeps where it pointed when slow.
-- Only while the car is mostly upright and not doing a stunt, a spin is damped in any position
function getHeadingCommand(vehicle, forward, up, spin, flight, stunting)
    local command = -YAW_DAMPING * spin.z
    local nose = vector3(forward.x, forward.y, 0.0)
    if stunting or up.z < 0.5 or #nose < 0.3 then
        return command
    end
    nose = nose / #nose

    local velocity = GetEntityVelocity(vehicle)
    local travel = vector3(velocity.x, velocity.y, 0.0)
    local target
    if #travel >= MIN_TRAVEL_SPEED then
        target = travel / #travel
        if dot(target, nose) < 0 then
            target = target * -1.0
        end
        flight.heldHeading = nil
    else
        flight.heldHeading = flight.heldHeading or nose
        target = flight.heldHeading
    end

    -- Angle from the nose to the target, > 0 when the target is to the left
    local headingError = math.atan(nose.x * target.y - nose.y * target.x, dot(nose, target))
    return command + HEADING_GAIN * headingError
end

-- Throttle of each nozzle: the shared lift on the corners plus each nozzle's share of the turns it can help with. Thrusters only push,
-- so a nozzle that would turn the wrong way stays off. Also returns the shared lift of each nozzle: only that part moves the car, the
-- corrections only turn it (like paired attitude jets), so levelling, rolls and heading never shove the car off its line
function mixFlightThrottles(vehicle, liftThrottle, pitchCommand, rollCommand, yawCommand)
    local _, torques = getNozzleGeometry(vehicle)
    local pitchArm, rollArm, yawArm = 0.0, 0.0, 0.0
    for _, index in ipairs(flightNozzles) do
        pitchArm = math.max(pitchArm, math.abs(torques[index].x))
        rollArm = math.max(rollArm, math.abs(torques[index].y))
        yawArm = math.max(yawArm, math.abs(torques[index].z))
    end

    local corrections = {}
    local strongestLiftCorrection = 0.0
    for _, index in ipairs(flightNozzles) do
        local torque = torques[index]
        local correction = 0.0
        if pitchArm > 0 then
            correction = correction + pitchCommand * torque.x / pitchArm
        end
        if rollArm > 0 then
            correction = correction + rollCommand * torque.y / rollArm
        end
        if yawArm > 0 then
            correction = correction + yawCommand * torque.z / yawArm
        end
        corrections[index] = correction
        if NOZZLES[index].group == "lift" then
            strongestLiftCorrection = math.max(strongestLiftCorrection, correction)
        end
    end

    -- Turning comes first: the shared lift leaves room for the strongest correction of a lift nozzle
    local base = math.min(liftThrottle, math.max(0.0, 1.0 - strongestLiftCorrection))
    local throttles = {}
    local lift = {}
    for _, index in ipairs(flightNozzles) do
        local shared = NOZZLES[index].group == "lift" and base or 0.0
        throttles[index] = clamp(shared + corrections[index], 0.0, 1.0)
        lift[index] = math.min(shared, throttles[index])
    end
    return throttles, lift
end
