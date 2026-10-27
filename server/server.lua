-----------------------------------------------------------------------------------------------------------------------------------------
-- Versioning
-----------------------------------------------------------------------------------------------------------------------------------------

version = ''
local UTILS_REQUIRED_VERSION = '1.2.1'

function checkVersion()
    CreateThread(function()
        local connected = false
        local attempts = 0
        while not connected and attempts < 3 do
            attempts = attempts + 1

            PerformHttpRequest("https://raw.githubusercontent.com/LeonardoSoares98/lc_thrusters/main/version", function(errorCode, resultData)
                if errorCode == 200 and resultData then
                    connected = true
                    local latestVersion = Utils.Math.trim(resultData)
                    if Utils.Math.checkIfCurrentVersionisOutdated(latestVersion, version) then
                        print("^4["..GetCurrentResourceName().."] An update is available, download it in https://github.com/LeonardoSoares98/lc_thrusters/releases/latest/download/lc_thrusters.zip^7 ^3[v"..latestVersion.."]^7")
                    end
                end
            end, "GET", "", {})

            Wait(10000)
        end
    end)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Script global variables
-----------------------------------------------------------------------------------------------------------------------------------------

Utils = Utils or exports['lc_utils']:GetUtils()

local SAVE_INTERVAL = 60             -- s between database saves of the changed tank levels (also saved when the resource stops)
local MIN_SYNC_GAP = 200            -- ms between two tank syncs of the same vehicle that raise the tank, extra ones are dropped
local REFILL_TOLERANCE = 1.1        -- A sync may refill up to 10% more than the compressor did since the last one (timing differences)
local tankDriver = {}               -- [vehicle] = source of the player allowed to sync its tank (the driver that asked the callback)
local tankSyncedAt = {}             -- [vehicle] = GetGameTimer() of the last accepted sync (or of the driver entering)
local MIN_FX_GAP = 50               -- ms between two effect changes of the same vehicle, extra ones are dropped
local MAX_FX_MASK = 0xFFFF          -- Effects are bits: bit n-1 = nozzle n firing, bit 15 = suction fan
local fxChangedAt = {}              -- [vehicle] = GetGameTimer() of the last accepted effect change

-- Database (Config.Database), cached by normalised plate
local installedPlates = {}          -- [plate] = true: the package was installed on this vehicle
local savedTanks = {}               -- [plate] = tank level saved in the database
local unsavedTanks = {}             -- [plate] = true: the tank changed since the last save
local ownedPlates = {}              -- [plate] = whether a player owns the vehicle (only owned or installed vehicles have their tank saved)

-- Model hashes (unsigned 32-bit) of the vehicles that come with the thruster package
local thrusterModelHashes = {}
for model, enabled in pairs(Config.Vehicles) do
    if enabled then
        thrusterModelHashes[GetHashKey(model) & 0xFFFFFFFF] = true
    end
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Script functions
-----------------------------------------------------------------------------------------------------------------------------------------

-- The package comes with the model (Config.Vehicles), or was installed on this vehicle (Config.Database)
function vehicleHasThrusters(vehicle)
    return thrusterModelHashes[GetEntityModel(vehicle) & 0xFFFFFFFF] == true or installedPlates[getVehiclePlate(vehicle)] == true
end

-- The driver asks if the vehicle has the package. Answering yes also starts the tank the first time (saved level, or full) and makes
-- that player the one allowed to sync it
Utils.Callback.RegisterServerCallback('lc_thrusters:hasThrusters', function(source, cb, netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) or not vehicleHasThrusters(vehicle) then
        cb(false)
        return
    end

    local state = Entity(vehicle).state
    if state.thrusterTank == nil then
        -- The saved level (clamped, in case the capacity was lowered since), or full
        state:set('thrusterTank', math.min(savedTanks[getVehiclePlate(vehicle)] or Config.Tank.capacity, Config.Tank.capacity), true)
    end
    if GetPedInVehicleSeat(vehicle, -1) == GetPlayerPed(source) then
        tankDriver[vehicle] = source
        tankSyncedAt[vehicle] = GetGameTimer()
    end
    cb(true)
end)

-- The driver sends the tank level. It can always go down, but it can only go up as much as the compressor refills since the last sync
RegisterServerEvent("lc_thrusters:syncTank")
AddEventHandler("lc_thrusters:syncTank",function(netId, level)
    local source = source
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if type(level) ~= "number" or level ~= level or vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end
    if tankDriver[vehicle] ~= source then
        return
    end

    local now = GetGameTimer()
    local elapsed = now - (tankSyncedAt[vehicle] or now)
    local state = Entity(vehicle).state
    local current = state.thrusterTank or Config.Tank.capacity
    -- Too frequent syncs may only lower the tank: each sync allows a little refill, and the last one (the driver leaving) must not be lost
    if elapsed < MIN_SYNC_GAP and level >= current then
        return
    end

    local maxLevel = math.min(Config.Tank.capacity, current + Config.Tank.rechargeRate * (elapsed / 1000) * REFILL_TOLERANCE)
    level = math.max(0.0, math.min(level, maxLevel))
    tankSyncedAt[vehicle] = now
    state:set('thrusterTank', level, true)
    rememberTank(vehicle, level)
end)

-- The driver reports which thrusters are working, every client shows them from the vehicle state 'thrusterFx'
RegisterServerEvent("lc_thrusters:setFx")
AddEventHandler("lc_thrusters:setFx",function(netId, mask)
    local source = source
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if math.type(mask) ~= "integer" or mask < 0 or mask > MAX_FX_MASK or vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end
    if tankDriver[vehicle] ~= source then
        return
    end

    local now = GetGameTimer()
    if fxChangedAt[vehicle] and now - fxChangedAt[vehicle] < MIN_FX_GAP then
        return
    end
    local state = Entity(vehicle).state
    if (state.thrusterFx or 0) ~= mask then
        fxChangedAt[vehicle] = now
        state:set('thrusterFx', mask, true)
    end
end)

-- A driver that disconnects can't turn the effects off, so the server does
AddEventHandler('playerDropped', function()
    local source = source
    for vehicle, driver in pairs(tankDriver) do
        if driver == source then
            if DoesEntityExist(vehicle) and Entity(vehicle).state.thrusterFx then
                Entity(vehicle).state:set('thrusterFx', 0, true)
            end
            tankDriver[vehicle] = nil
        end
    end
end)

AddEventHandler('entityRemoved', function(entity)
    tankDriver[entity] = nil
    tankSyncedAt[entity] = nil
    fxChangedAt[entity] = nil
end)

-- Sets a vehicle's tank from the server (exports): its driver takes the new level at once, instead of syncing its old one back
function setTankLevel(vehicle, level)
    level = math.max(0.0, math.min(tonumber(level) or 0.0, Config.Tank.capacity))
    Entity(vehicle).state:set('thrusterTank', level, true)
    tankSyncedAt[vehicle] = GetGameTimer()
    rememberTank(vehicle, level)
    if tankDriver[vehicle] then
        TriggerClientEvent("lc_thrusters:setTankLevel", tankDriver[vehicle], NetworkGetNetworkIdFromEntity(vehicle), level)
    end
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Database
-----------------------------------------------------------------------------------------------------------------------------------------

-- Keeps the tank level to save, for installed vehicles and vehicles a player owns (not for every NPC car with the model)
function rememberTank(vehicle, level)
    if not Config.Database.enabled then
        return
    end
    local plate = getVehiclePlate(vehicle)
    if ownedPlates[plate] == nil then
        ownedPlates[plate] = Utils.Framework.getVehicleOwner(plate) ~= false
    end
    if installedPlates[plate] or ownedPlates[plate] then
        savedTanks[plate] = level
        unsavedTanks[plate] = true
    end
end

function saveTanks()
    for plate in pairs(unsavedTanks) do
        local sql = "INSERT INTO `vehicle_thrusters` (plate, tank) VALUES (@plate, @tank) ON DUPLICATE KEY UPDATE tank = @tank"
        Utils.Database.execute(sql, {['@plate'] = plate, ['@tank'] = savedTanks[plate]})
    end
    unsavedTanks = {}
end

-- Installs or removes the package on a plate. Every player re-checks the vehicle they drive, so it works without getting out
function setThrustersInstalled(plate, installed)
    if not Config.Database.enabled then
        print("^3[lc_thrusters] Installing the package on a plate needs Config.Database.enabled^7")
        return false
    end
    plate = normalizePlate(plate)
    local sql = "INSERT INTO `vehicle_thrusters` (plate, installed) VALUES (@plate, @installed) ON DUPLICATE KEY UPDATE installed = @installed"
    Utils.Database.execute(sql, {['@plate'] = plate, ['@installed'] = installed and 1 or 0})
    installedPlates[plate] = installed or nil
    TriggerClientEvent("lc_thrusters:recheckVehicle", -1)
    return true
end

function createSaveTanksThread()
    CreateThread(function()
        while true do
            Wait(SAVE_INTERVAL * 1000)
            saveTanks()
        end
    end)
end

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() and Config.Database.enabled then
        saveTanks()
    end
end)

-- Admin commands on the vehicle the admin sits in. Restricted: they need the ACE permission "command.<name>"
function registerAdminCommands()
    RegisterCommand(Config.Database.installCommand, function(source)
        runAdminCommand(source, true)
    end, true)
    RegisterCommand(Config.Database.removeCommand, function(source)
        runAdminCommand(source, false)
    end, true)
end

function runAdminCommand(source, install)
    if source <= 0 then
        return
    end
    local vehicle = GetVehiclePedIsIn(GetPlayerPed(source), false)
    if vehicle == 0 then
        TriggerClientEvent("lc_thrusters:Notify", source, "error", Utils.translate('not_in_vehicle'))
        return
    end
    local plate = getVehiclePlate(vehicle)
    if not install and thrusterModelHashes[GetEntityModel(vehicle) & 0xFFFFFFFF] then
        TriggerClientEvent("lc_thrusters:Notify", source, "error", Utils.translate('thrusters_by_model'))
    elseif (installedPlates[plate] == true) == install then
        local key = install and 'thrusters_already_installed' or 'thrusters_not_installed'
        TriggerClientEvent("lc_thrusters:Notify", source, "error", Utils.translate(key):format(plate))
    elseif setThrustersInstalled(plate, install) then
        local key = install and 'thrusters_installed' or 'thrusters_removed'
        TriggerClientEvent("lc_thrusters:Notify", source, "success", Utils.translate(key):format(plate))
    end
end

function runCreateTableQueries()
    Utils.Database.execute([[
        CREATE TABLE IF NOT EXISTS `vehicle_thrusters` (
            `plate` VARCHAR(20) NOT NULL COLLATE 'utf8_general_ci',
            `installed` TINYINT(1) NOT NULL DEFAULT 0,
            `tank` FLOAT NULL DEFAULT NULL,
            PRIMARY KEY (`plate`) USING BTREE
        )
        COLLATE='utf8_general_ci'
        ENGINE=InnoDB
        ;
    ]])
end

function cacheVehicleThrusters()
    local queryData = Utils.Database.fetchAll("SELECT plate, installed, tank FROM vehicle_thrusters", {})
    for _, value in pairs(queryData) do
        local plate = normalizePlate(value.plate)
        installedPlates[plate] = value.installed == 1 or value.installed == true or nil
        savedTanks[plate] = value.tank
    end
    print("^2[lc_thrusters] #"..#queryData.." Vehicles successfully fetched from database^7")
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Exports
-----------------------------------------------------------------------------------------------------------------------------------------

-- For other scripts, like a mechanic or dealership selling the package. vehicle is a server entity handle, plate any padding or case
exports('HasThrusters', function(vehicle)
    return DoesEntityExist(vehicle) and vehicleHasThrusters(vehicle)
end)

exports('IsThrustersInstalled', function(plate)
    return installedPlates[normalizePlate(plate)] == true
end)

exports('InstallThrusters', function(plate)
    return setThrustersInstalled(plate, true)
end)

exports('RemoveThrusters', function(plate)
    return setThrustersInstalled(plate, false)
end)

exports('GetTankLevel', function(vehicle)
    if not DoesEntityExist(vehicle) then
        return nil
    end
    return Entity(vehicle).state.thrusterTank
end)

exports('SetTankLevel', function(vehicle, level)
    if DoesEntityExist(vehicle) then
        setTankLevel(vehicle, level)
    end
end)

-----------------------------------------------------------------------------------------------------------------------------------------
-- Utils functions
-----------------------------------------------------------------------------------------------------------------------------------------

-- Plates are kept as other scripts know them: trimmed and upper case (GTA pads plate texts with spaces)
function normalizePlate(plate)
    return string.upper((string.gsub(tostring(plate), "^%s*(.-)%s*$", "%1")))
end

function getVehiclePlate(vehicle)
    return normalizePlate(GetVehicleNumberPlateText(vehicle))
end

Citizen.CreateThread(function()
    Wait(1000)

    -- Load version number from file
    local versionFile = LoadResourceFile(GetCurrentResourceName(), "version")
    if versionFile then
        version = Utils.Math.trim(versionFile)
        print("^2[lc_thrusters] Loaded! Support discord: https://discord.gg/U5YDgbh ^3[v"..version.."]^7")
    else
        error("^1[lc_thrusters] Warning: Could not load the version file.^7")
    end

    checkScriptName()

    -- Check lc_utils dependency
    assert(GetResourceState('lc_utils') == 'started', "^3The '^1lc_utils^3' file is missing. Download it in: ^7https://github.com/LeonardoSoares98/lc_utils/releases/latest/download/lc_utils.zip^7")
    if Utils.Math.checkIfCurrentVersionisOutdated(UTILS_REQUIRED_VERSION, Utils.Version) then
        error("^3The script requires 'lc_utils' in version ^1"..UTILS_REQUIRED_VERSION.."^3, but you currently have version ^1"..Utils.Version.."^3. Please update your 'lc_utils' script to the latest version: https://github.com/LeonardoSoares98/lc_utils/releases/latest/download/lc_utils.zip^7")
    end

    Utils.loadLanguageFile(Lang)

    if Config.Database.enabled then
        checkIfFrameworkWasLoaded()
        runCreateTableQueries()
        cacheVehicleThrusters()
        createSaveTanksThread()
        registerAdminCommands()
    end

    Wait(1000)

    checkVersion()
end)

function checkIfFrameworkWasLoaded()
    assert(Utils.Framework.getVehicleOwner, "^3The framework wasn't loaded in the '^1lc_utils^3' resource. Please check if the '^1Config.framework^3' is correctly set to your framework (Config.Database needs it).^7")
end

function checkScriptName()
    assert(GetCurrentResourceName() == "lc_thrusters", "^3The script name does not match the expected resource name. Please ensure that the current resource name is set to '^1lc_thrusters^7'.")
end
