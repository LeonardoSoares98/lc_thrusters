-- Nozzle model shared by the boost, the flight computer and the effects. Every nozzle in NOZZLES is fixed to the chassis, and its
-- push is applied at its own position (ApplyForceToEntity), so the game's mass and inertia turn an off-centre push into rotation

-- The 10 cold-gas nozzles of the package: 4 main thrusters in the rear diffuser, 4 underbody corner thrusters for lift
-- and landing, and 1 side thruster on each side at the front, which turn the nose (and help roll). Each nozzle pushes the opposite way its
-- gas goes out, from its own position
--   group:           "rear" (fired by the boost), "lift" or "side" (fired by the flight computer)
--   position:        fractions of the vehicle's size: x -1 (left) to 1 (right), y -1 (rear) to 1 (front), z -1 (bottom) to 1 (top)
--   exhaust:         direction the gas goes out, in the vehicle's frame
--   maxAcceleration: m/s² this nozzle gives the whole vehicle at full throttle
--   plumeRotation:   turns the particle (pitch, roll, yaw in degrees) so its jet follows the exhaust
-- At most 15 nozzles (the effects send them as bits)
NOZZLES = {
    { group = "rear", position = vector3(-0.45, -1.0, -0.3), exhaust = vector3(0.0, -1.0, 0.0), maxAcceleration = 5.0, plumeRotation = vector3(90.0, 0.0, 0.0) },
    { group = "rear", position = vector3(-0.15, -1.0, -0.3), exhaust = vector3(0.0, -1.0, 0.0), maxAcceleration = 5.0, plumeRotation = vector3(90.0, 0.0, 0.0) },
    { group = "rear", position = vector3(0.15, -1.0, -0.3), exhaust = vector3(0.0, -1.0, 0.0), maxAcceleration = 5.0, plumeRotation = vector3(90.0, 0.0, 0.0) },
    { group = "rear", position = vector3(0.45, -1.0, -0.3), exhaust = vector3(0.0, -1.0, 0.0), maxAcceleration = 5.0, plumeRotation = vector3(90.0, 0.0, 0.0) },
    { group = "lift", position = vector3(-0.8, 0.75, -1.0), exhaust = vector3(0.0, 0.0, -1.0), maxAcceleration = 7.0, plumeRotation = vector3(180.0, 0.0, 0.0) },
    { group = "lift", position = vector3(0.8, 0.75, -1.0), exhaust = vector3(0.0, 0.0, -1.0), maxAcceleration = 7.0, plumeRotation = vector3(180.0, 0.0, 0.0) },
    { group = "lift", position = vector3(-0.8, -0.75, -1.0), exhaust = vector3(0.0, 0.0, -1.0), maxAcceleration = 7.0, plumeRotation = vector3(180.0, 0.0, 0.0) },
    { group = "lift", position = vector3(0.8, -0.75, -1.0), exhaust = vector3(0.0, 0.0, -1.0), maxAcceleration = 7.0, plumeRotation = vector3(180.0, 0.0, 0.0) },
    { group = "side", position = vector3(-1.0, 0.6, -0.5), exhaust = vector3(-1.0, 0.0, 0.0), maxAcceleration = 4.0, plumeRotation = vector3(0.0, -90.0, 0.0) },
    { group = "side", position = vector3(1.0, 0.6, -0.5), exhaust = vector3(1.0, 0.0, 0.0), maxAcceleration = 4.0, plumeRotation = vector3(0.0, 90.0, 0.0) },
}

-- Gas used is proportional to the push, like a real cold-gas thruster (push = gas flow x exhaust speed): tank units per second for each
-- m/s² a nozzle gives. A stronger nozzle drains the tank faster, so no nozzle gets more out of the tank than another
GAS_PER_ACCELERATION = 1.0

nozzleThrottles = {}        -- [nozzle index] = throttle 0..1 the driver's thrusters fire at (read by the effects)

-- How a push reaches the car, the same at any frame rate:
--   Moving: the nozzles' combined acceleration is added to the car's speed every frame (speed + acceleration x frame time). The speed is
--   set directly, so nothing is lost: impulses (ApplyForceToEntity) were exact at 50 fps but at 165 fps the physics lost many of them,
--   and the lift couldn't beat gravity anymore.
--   Turning: each nozzle also pushes from its own position with a pair of opposite impulses (one at the nozzle, one at the car's origin).
--   The pair adds no speed, only the turn an off-centre nozzle makes. If the physics loses part of it the car turns a little slower, and
--   the flight computer, which watches how the car turns, makes up for it. Impulses are gathered and applied at most about 60 times a
--   second, so each one is the size the physics handles well
local IMPULSE_TYPE = 1
local MIN_PUSH_TIME = 1 / 65        -- s of turning push gathered before it is applied (every frame at 60 fps or less)
local STALE_PUSH_TIME = 100         -- ms after which turning push still gathered from an earlier burst is dropped
local pushVehicle = 0               -- Vehicle the gathered turning push below belongs to
local pendingPushes = {}            -- [nozzle index] = { push = gathered acceleration x time (vector), time = s, at = ms }
local GROUND_PROBE_FLAGS = 1 | 2 | 16   -- The ground probe hits the map, vehicles and objects
local WHEEL_BONES = { "wheel_lf", "wheel_rf", "wheel_lr", "wheel_rr" }
local WHEEL_TO_BODY_EDGE = 0.2  -- m from a wheel's centre to the side of the body (half a tyre plus the fender)
local carExtents = {}       -- [model] = { min, max }: the size the nozzle fractions apply to
local geometryModel = 0     -- Model the cached nozzle geometry below belongs to
local nozzleOffsets = {}    -- [nozzle index] = position from the vehicle origin
local nozzleTorques = {}    -- [nozzle index] = turn per unit of thrust around the car's centre: x nose up, y right side down, z nose left

-----------------------------------------------------------------------------------------------------------------------------------------
-- Functions
-----------------------------------------------------------------------------------------------------------------------------------------

-- Corners of the box the nozzle fractions apply to, cached by model: the model's bounding box, but as wide as the wheels say. Some
-- models' boxes are much wider than the body (hidden or mod parts), and the nozzles would end up out in the air. The box is only ever
-- narrowed, and kept as it is for a model without wheel bones
function getCarExtents(vehicle)
    local model = GetEntityModel(vehicle)
    if not carExtents[model] then
        local min, max = GetModelDimensions(model)
        local halfWidth = nil
        for _, bone in ipairs(WHEEL_BONES) do
            local boneIndex = GetEntityBoneIndexByName(vehicle, bone)
            if boneIndex ~= -1 then
                local wheel = GetOffsetFromEntityGivenWorldCoords(vehicle, GetWorldPositionOfEntityBone(vehicle, boneIndex))
                halfWidth = math.max(halfWidth or 0.0, math.abs(wheel.x) + WHEEL_TO_BODY_EDGE)
            end
        end
        if halfWidth and halfWidth < (max.x - min.x) / 2 then
            min = vector3(-halfWidth, min.y, min.z)
            max = vector3(halfWidth, max.y, max.z)
        end
        carExtents[model] = { min = min, max = max }
    end
    return carExtents[model].min, carExtents[model].max
end

-- Position of a nozzle from the vehicle origin, by the fractions of the car's size in its config
function getNozzleOffset(vehicle, nozzle)
    local min, max = getCarExtents(vehicle)
    local center = (min + max) / 2
    local half = (max - min) / 2
    return vector3(center.x + nozzle.position.x * half.x, center.y + nozzle.position.y * half.y, center.z + nozzle.position.z * half.z)
end

-- Offsets and turning effect of every nozzle of the vehicle, cached by model
function getNozzleGeometry(vehicle)
    local model = GetEntityModel(vehicle)
    if model ~= geometryModel then
        local min, max = getCarExtents(vehicle)
        local center = (min + max) / 2
        for index, nozzle in ipairs(NOZZLES) do
            local offset = getNozzleOffset(vehicle, nozzle)
            nozzleOffsets[index] = offset
            nozzleTorques[index] = cross(offset - center, nozzle.exhaust * -1.0)
        end
        geometryModel = model
    end
    return nozzleOffsets, nozzleTorques
end

-- Adds an acceleration in the vehicle's own frame (x right, y forward, z up) to its speed for one frame, whatever its mass
function addLocalAcceleration(vehicle, acceleration, dt)
    local forward = GetEntityForwardVector(vehicle)
    local _, _, up = GetEntityMatrix(vehicle)
    local right = cross(forward, up)
    local velocity = GetEntityVelocity(vehicle) + (right * acceleration.x + forward * acceleration.y + up * acceleration.z) * dt
    SetEntityVelocity(vehicle, velocity.x, velocity.y, velocity.z)
end

-- Pulls the vehicle for one frame with an acceleration in its own frame, from its centre (the suction fan pulls along its down direction)
function applyCentralAcceleration(vehicle, acceleration, dt)
    addLocalAcceleration(vehicle, acceleration, dt)
end

-- The turn of one nozzle's push for one frame: the push at the nozzle and the opposite push at the car's origin, so only the turn is left.
-- Scaled by the vehicle's mass like the speed change, so a nozzle turns any vehicle alike
function applyNozzleTurn(vehicle, index, push, dt)
    local now = GetGameTimer()
    if vehicle ~= pushVehicle then
        pendingPushes = {}
        pushVehicle = vehicle
    end
    local pending = pendingPushes[index]
    if not pending or now - pending.at > STALE_PUSH_TIME then
        pending = { push = vector3(0.0, 0.0, 0.0), time = 0.0 }
        pendingPushes[index] = pending
    end
    pending.push = pending.push + push * dt
    pending.time = pending.time + dt
    pending.at = now
    if pending.time < MIN_PUSH_TIME then
        return
    end
    pendingPushes[index] = nil

    local offset = getNozzleGeometry(vehicle)[index]
    local impulse = pending.push
    ApplyForceToEntity(vehicle, IMPULSE_TYPE, impulse.x, impulse.y, impulse.z, offset.x, offset.y, offset.z, 0, true, true, true, false, true)
    ApplyForceToEntity(vehicle, IMPULSE_TYPE, -impulse.x, -impulse.y, -impulse.z, 0.0, 0.0, 0.0, 0, true, true, true, false, true)
end

-- Fires a set of nozzles this frame: throttles is [nozzle index] = 0..1. The gas comes from the tank first, and nothing fires (returns
-- false) when there isn't enough. useReserve lets the assists use the gas kept for them (see consumeTank). movingThrottles (optional) is
-- the part of each throttle that moves the car: the rest only turns it. Without it, all of it moves the car
function fireNozzles(vehicle, throttles, dt, useReserve, movingThrottles)
    local gas = 0.0
    for index, throttle in pairs(throttles) do
        gas = gas + NOZZLES[index].maxAcceleration * GAS_PER_ACCELERATION * throttle * dt
    end
    if gas > 0 and not consumeTank(gas, useReserve) then
        return false
    end
    -- Each nozzle pushes opposite to its exhaust: all together they move the car, each one turns it from where it sits
    local acceleration = vector3(0.0, 0.0, 0.0)
    for index, throttle in pairs(throttles) do
        if throttle > 0 then
            local nozzle = NOZZLES[index]
            local push = nozzle.exhaust * -(nozzle.maxAcceleration * throttle)
            local moving = movingThrottles and (movingThrottles[index] or 0.0) or throttle
            acceleration = acceleration + nozzle.exhaust * -(nozzle.maxAcceleration * moving)
            applyNozzleTurn(vehicle, index, push, dt)
        end
        nozzleThrottles[index] = throttle
    end
    if acceleration.x ~= 0 or acceleration.y ~= 0 or acceleration.z ~= 0 then
        addLocalAcceleration(vehicle, acceleration, dt)
    end
    return true
end

-- Sets the throttle the effects read back to 0 for the nozzles of a group
function stopNozzleGroup(group)
    for index, nozzle in ipairs(NOZZLES) do
        if nozzle.group == group then
            nozzleThrottles[index] = nil
        end
    end
end

-- Distance from the vehicle's origin straight down to whatever is under it (map, vehicles, objects), or nil if nothing within range
function getGroundDistance(vehicle, range)
    local position = GetEntityCoords(vehicle)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(position.x, position.y, position.z, position.x, position.y, position.z - range,
        GROUND_PROBE_FLAGS, vehicle, 7)
    local _, hit, hitCoords = GetShapeTestResult(probe)
    if hit ~= 1 and hit ~= true then
        return nil
    end
    return position.z - hitCoords.z
end

function getNozzleIndexes(group)
    local indexes = {}
    for index, nozzle in ipairs(NOZZLES) do
        if nozzle.group == group then
            indexes[#indexes + 1] = index
        end
    end
    return indexes
end

function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

function cross(a, b)
    return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end
