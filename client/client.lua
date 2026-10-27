-- Shared variables
Utils = Utils or exports['lc_utils']:GetUtils()

currentVehicle = 0          -- Vehicle with thrusters the player is driving (0 = none)
tankLevel = 0.0             -- Local copy of the vehicle's tank, sent to the server state bag 'thrusterTank'

-- Local variables
local TANK_SYNC_INTERVAL = 2000 -- ms between tank updates sent to the server while it changes
local ASSIST_RESERVE = 0.20     -- Share of the tank kept for the assists (stability, landing): boost, climb and stunts stop at this level
local CALLBACK_TIMEOUT = 5000   -- ms to wait for the server's answer before treating the vehicle as one without thrusters
local tankDirty = false     -- tankLevel changed since the last sync
local lastTankSync = 0
local recheckVehicle = false    -- The package was installed or removed somewhere: ask the server again about the current vehicle

-----------------------------------------------------------------------------------------------------------------------------------------
-- Threads
-----------------------------------------------------------------------------------------------------------------------------------------

-- Thread to detect when the player drives a vehicle with thrusters, and to recharge and sync its tank
function createVehicleDetectionThread()
    CreateThread(function()
        local checkedVehicle = 0    -- Last vehicle asked to the server, so it's asked only once per entry
        while true do
            Wait(1000)
            local ped = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)
            if recheckVehicle then
                checkedVehicle = 0
                recheckVehicle = false
            end
            if vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped then
                if vehicle ~= checkedVehicle then
                    if currentVehicle ~= 0 then
                        leaveThrusterVehicle()
                    end
                    checkedVehicle = vehicle
                    if getVehicleHasThrustersFromServer(vehicle) then
                        enterThrusterVehicle(vehicle)
                    end
                end
                if currentVehicle ~= 0 then
                    rechargeTank(1.0)
                    syncTank(false)
                end
            else
                if currentVehicle ~= 0 then
                    leaveThrusterVehicle()
                end
                checkedVehicle = 0
            end
        end
    end)
end

RegisterNetEvent('lc_thrusters:Notify')
AddEventHandler('lc_thrusters:Notify', function(type, message)
    exports['lc_utils']:notify(type, message)
end)

RegisterNetEvent('lc_thrusters:recheckVehicle')
AddEventHandler('lc_thrusters:recheckVehicle', function()
    recheckVehicle = true
end)

-- The server set the tank (an export, like a refill): take its level instead of syncing the old one back
RegisterNetEvent('lc_thrusters:setTankLevel')
AddEventHandler('lc_thrusters:setTankLevel', function(netId, level)
    if currentVehicle ~= 0 and VehToNet(currentVehicle) == netId then
        tankLevel = level
        tankDirty = false
    end
end)

Citizen.CreateThread(function()
    Wait(1000)
    SetNuiFocus(false,false)
    SetNuiFocusKeepInput(false)

    Utils.loadLanguageFile(Lang)

    if Config.Boost.enabled then
        createBoostKeybind()
    end
    if Config.Flight.enabled then
        createFlightKeybind()
        createFlightMonitorThread()
    end
    if Config.Suction.enabled then
        createSuctionKeybind()
    end
    if Config.Effects.enabled then
        createEffectsThreads()
    end

    createVehicleDetectionThread()
    createInterface()
end)

-----------------------------------------------------------------------------------------------------------------------------------------
-- Tank
-----------------------------------------------------------------------------------------------------------------------------------------

function enterThrusterVehicle(vehicle)
    -- The server starts the tank in the same callback, wait a moment for the state bag to arrive
    local state = Entity(vehicle).state
    local timeout = GetGameTimer() + 1000
    while state.thrusterTank == nil and GetGameTimer() < timeout do
        Wait(10)
    end

    currentVehicle = vehicle
    tankLevel = state.thrusterTank or Config.Tank.capacity
    tankDirty = false
    lastTankSync = GetGameTimer()
end

function leaveThrusterVehicle()
    syncTank(true)
    currentVehicle = 0
    tankLevel = 0.0
    tankDirty = false
end

function rechargeTank(seconds)
    if Config.Tank.rechargeRate <= 0 or tankLevel >= Config.Tank.capacity then
        return
    end
    tankLevel = math.min(Config.Tank.capacity, tankLevel + Config.Tank.rechargeRate * seconds)
    tankDirty = true
end

-- Used by the thrusters: takes the amount from the tank, or returns false (and takes nothing) when there isn't enough. What the player
-- fires (boost, climb, stunts) can't use the last ASSIST_RESERVE of the tank, which is kept for the assists (useReserve)
function consumeTank(amount, useReserve)
    local floor = useReserve and 0.0 or getTankReserve()
    if currentVehicle == 0 or tankLevel - amount < floor then
        return false
    end
    tankLevel = tankLevel - amount
    tankDirty = true
    return true
end

function getTankReserve()
    return Config.Tank.capacity * ASSIST_RESERVE
end

-- The player's own thruster use still has gas above the assist reserve
function hasPlayerGas()
    return tankLevel > getTankReserve()
end

function syncTank(force)
    if not tankDirty or currentVehicle == 0 or not DoesEntityExist(currentVehicle) then
        return
    end
    local now = GetGameTimer()
    if not force and now - lastTankSync < TANK_SYNC_INTERVAL then
        return
    end
    TriggerServerEvent("lc_thrusters:syncTank", VehToNet(currentVehicle), tankLevel)
    tankDirty = false
    lastTankSync = now
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Utils
-----------------------------------------------------------------------------------------------------------------------------------------

function getVehicleHasThrustersFromServer(vehicle)
    if not NetworkGetEntityIsNetworked(vehicle) then
        return false
    end

    local returnHasThrusters = nil

    Utils.Callback.TriggerServerCallback('lc_thrusters:hasThrusters', function(hasThrusters)
        returnHasThrusters = hasThrusters
    end, VehToNet(vehicle))

    local timeout = GetGameTimer() + CALLBACK_TIMEOUT
    while returnHasThrusters == nil and GetGameTimer() < timeout do
        Wait(10)
    end
    return returnHasThrusters == true
end
