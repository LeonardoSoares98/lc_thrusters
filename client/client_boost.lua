-- Rear thrusters: the 4 main nozzles in the rear diffuser fire while the key is held. They push along the car's own forward direction
-- from below its centre, so a hard push also lifts the nose a little, and in the air they push wherever the car points.
-- The boost overheats: it has maxDuration of firing, which drains while it fires and refills over cooldown while it doesn't. Fully drained,
-- it's locked until fully cooled. On average it can fire only maxDuration / (maxDuration + cooldown) of the time, too little to beat
-- gravity pointing up, so tapping the key can't climb forever

-- Do not load anything here if the boost is disabled
if not Config.Boost.enabled then
    return
end

isBoosting = false
boostCharge = 1.0           -- Share of maxDuration left to fire (read by the readout)
boostOverheated = false     -- Fully drained: locked until the charge is full again

local MIN_UPWARD = 0.1      -- Forward direction pointing up this much counts as climbing

local isBoostKeyDown = false
local lastChargeUpdate = GetGameTimer()
local rearNozzles = getNozzleIndexes("rear")

-----------------------------------------------------------------------------------------------------------------------------------------
-- Threads
-----------------------------------------------------------------------------------------------------------------------------------------

-- Fires the rear nozzles every frame while the key is held, below maxSpeed, until the charge runs out
function createBoostThread(vehicle)
    CreateThread(function()
        isBoosting = true
        local ped = PlayerPedId()
        local maxSpeed = Config.Boost.maxSpeed / 3.6
        while isBoostKeyDown and currentVehicle == vehicle and DoesEntityExist(vehicle) and GetPedInVehicleSeat(vehicle, -1) == ped do
            local dt = GetFrameTime()
            local throttle = GetEntitySpeed(vehicle) < maxSpeed and 1.0 or 0.0
            -- In the air, pushing upwards uses the lift's climb time (by how much the car points up). Once it's used, the nozzles
            -- stop while the car points up
            if Config.Flight.enabled then
                if not IsEntityInAir(vehicle) then
                    resetClimbTime()
                elseif throttle > 0 then
                    local upward = GetEntityForwardVector(vehicle).z
                    if upward > MIN_UPWARD then
                        if hasClimbTime() then
                            useClimbTime(dt * 1000 * upward)
                        else
                            throttle = 0.0
                        end
                    end
                end
            end
            local throttles = {}
            for _, index in ipairs(rearNozzles) do
                throttles[index] = throttle
            end
            if not fireNozzles(vehicle, throttles, dt, false) then
                break   -- Tank at the assist reserve (the readout shows it)
            end
            if throttle > 0 then
                boostCharge = boostCharge - dt * 1000 / Config.Boost.maxDuration
                if boostCharge <= 0 then
                    boostCharge = 0.0
                    boostOverheated = true
                    break
                end
            end
            Wait(0)
        end
        stopNozzleGroup("rear")
        isBoosting = false
        lastChargeUpdate = GetGameTimer()   -- Cooling starts now
    end)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Functions
-----------------------------------------------------------------------------------------------------------------------------------------

function createBoostKeybind()
    RegisterCommand('+lc_thrusters_boost', startBoost, false)
    RegisterCommand('-lc_thrusters_boost', function()
        isBoostKeyDown = false
    end, false)
    RegisterKeyMapping('+lc_thrusters_boost', Utils.translate('keybind_boost'), 'keyboard', Config.Boost.key)
end

function startBoost()
    isBoostKeyDown = true
    if isBoosting or currentVehicle == 0 or IsPauseMenuActive() then
        return
    end
    updateBoostCharge()
    if boostOverheated then
        return
    end
    createBoostThread(currentVehicle)
end

-- Refills the charge for the time spent not firing
function updateBoostCharge()
    local now = GetGameTimer()
    if not isBoosting then
        boostCharge = math.min(1.0, boostCharge + (now - lastChargeUpdate) / Config.Boost.cooldown)
        if boostCharge >= 1.0 then
            boostOverheated = false
        end
    end
    lastChargeUpdate = now
end
