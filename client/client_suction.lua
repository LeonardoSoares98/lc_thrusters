-- Underbody fan: sucks the vehicle onto the surface right under its floor, so it can hold banked, vertical and upside-down track. Like a
-- real fan it works at any speed: a slow run over a half loop holds as well as a fast one. The surface is found with a short probe along
-- the car's own down direction, so the pull doesn't drop when the tyres barely touch (upside down they carry little weight)

-- Do not load anything here if the suction fan is disabled
if not Config.Suction.enabled then
    return
end

isSuctionOn = false         -- Read by the effects for the fan sound
suctionHolding = false      -- The fan is holding the car on a surface right under it (the flight computer stays off meanwhile)

local DOWNFORCE = 15.0          -- m/s² pull towards the surface (about 1.5 g: upside down it still presses the tyres on with 0.5 g)
local SURFACE_RANGE = 1.5       -- m from the car's floor within which the fan finds a surface
local HOLD_GAP = 0.4            -- m from the floor within which the fan pulls even with the car "in the air" (tyres barely touching)
local PROBE_INTERVAL = 50       -- ms between surface probes
local PROBE_FLAGS = 1 | 2 | 16  -- The probe hits the map, vehicles and objects (stunt ramps are objects)
local GAS_PER_SECOND = 2.0      -- Tank units per second while the fan pulls (0 = free)

local suctionThreadId = 0    -- Turning the fan off and on again in the same frame must not leave two threads pushing

-----------------------------------------------------------------------------------------------------------------------------------------
-- Threads
-----------------------------------------------------------------------------------------------------------------------------------------

-- Runs every frame while the fan is on. It pulls along the vehicle's own down direction (not the world's) while a surface is under the
-- floor: on the ground, or within HOLD_GAP of it in the air, so jumps aren't pulled down. It stops while the lift key climbs, and when
-- the player leaves the vehicle
function createSuctionThread(vehicle)
    suctionThreadId = suctionThreadId + 1
    local threadId = suctionThreadId
    CreateThread(function()
        local ped = PlayerPedId()
        local probedAt, gap = 0, nil
        while isSuctionOn and threadId == suctionThreadId and currentVehicle == vehicle and DoesEntityExist(vehicle) and GetPedInVehicleSeat(vehicle, -1) == ped do
            local dt = GetFrameTime()
            local now = GetGameTimer()
            if now - probedAt >= PROBE_INTERVAL then
                gap = getSurfaceGap(vehicle)
                probedAt = now
            end
            local climbing = isLiftHeld and isLiftHeld()
            suctionHolding = gap ~= nil and gap <= HOLD_GAP and not climbing
            if gap and not climbing and (gap <= HOLD_GAP or not IsEntityInAir(vehicle)) then
                if GAS_PER_SECOND > 0 and not consumeTank(GAS_PER_SECOND * dt) then
                    break   -- Tank at the assist reserve (the readout shows it)
                end
                applyCentralAcceleration(vehicle, vector3(0.0, 0.0, -DOWNFORCE), dt)
            end
            Wait(0)
        end
        if threadId == suctionThreadId then
            isSuctionOn = false
            suctionHolding = false
        end
    end)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Functions
-----------------------------------------------------------------------------------------------------------------------------------------

function createSuctionKeybind()
    RegisterCommand('lc_thrusters_suction', toggleSuction, false)
    RegisterKeyMapping('lc_thrusters_suction', Utils.translate('keybind_suction'), 'keyboard', Config.Suction.key)
end

function toggleSuction()
    if currentVehicle == 0 or IsPauseMenuActive() then
        return
    end
    if isSuctionOn then
        isSuctionOn = false
    else
        isSuctionOn = true
        createSuctionThread(currentVehicle)
    end
end

-- Gap between the car's floor and the surface under it, along the car's own down direction (so a wall or a loop's ceiling counts), or nil
-- if nothing is within SURFACE_RANGE
function getSurfaceGap(vehicle)
    local min = GetModelDimensions(GetEntityModel(vehicle))
    local floor = -min.z                    -- From the car's origin down to its floor
    local position = GetEntityCoords(vehicle)
    local _, _, up = GetEntityMatrix(vehicle)
    local target = position - up * (floor + SURFACE_RANGE)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(position.x, position.y, position.z, target.x, target.y, target.z,
        PROBE_FLAGS, vehicle, 7)
    local _, hit, hitCoords = GetShapeTestResult(probe)
    if hit ~= 1 and hit ~= true then
        return nil
    end
    return math.max(0.0, #(hitCoords - position) - floor)
end
