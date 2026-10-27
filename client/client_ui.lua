-- Car screen (nui/ui.html, nui/panel.js): the thruster readout while driving and the control panel, where the driver turns the flight assists and the
-- fan on or off. The driver's choices are kept in this client's resource KVP, so they're remembered between sessions

local SETTINGS_KVP = "settings"
local HUD_ACTIVE_INTERVAL = 50      -- ms between readout updates while thrusters fire or the car is in the air
local HUD_IDLE_INTERVAL = 250       -- ms between readout updates otherwise
local ALTITUDE_RANGE = 150.0        -- m below the car within which the altitude is shown
local ASSISTS = { stabilityControl = true, landingAssist = true, stunts = true }
local HUD_POSITIONS = { ["top-left"] = true, ["top-right"] = true, ["bottom-left"] = true, ["bottom-right"] = true }
local KEY_COMMANDS = {               -- Key legend of the panel: the command each key is mapped to
    boost = "+lc_thrusters_boost",
    lift = "+lc_thrusters_lift",
    fan = "lc_thrusters_suction",
    panel = "lc_thrusters_panel",
    hud = "lc_thrusters_hud",
}
local NUI_RESEND_INTERVAL = 1000    -- ms between sends of the NUI variables until the page answers (a message sent before it loads is lost)
local NUI_TIMEOUT = 10000           -- ms after which a page that hasn't answered is reported

local playerSettings = json.decode(GetResourceKvpString(SETTINGS_KVP) or "{}") or {}
local isNuiVariablesLoaded = false
local isPanelOpen = false

-----------------------------------------------------------------------------------------------------------------------------------------
-- Threads
-----------------------------------------------------------------------------------------------------------------------------------------

function createInterface()
    RegisterCommand('lc_thrusters_panel', togglePanel, false)
    RegisterKeyMapping('lc_thrusters_panel', Utils.translate('keybind_panel'), 'keyboard', Config.Interface.panelKey)
    if Config.Interface.hud then
        RegisterCommand('lc_thrusters_hud', function()
            setHudVisible(playerSettings.hudHidden == true)
        end, false)
        RegisterKeyMapping('lc_thrusters_hud', Utils.translate('keybind_hud'), 'keyboard', Config.Interface.hudKey)
    end
    loadNuiVariables()
    SendNUIMessage({ setup = getUiSetup() })    -- After the key mappings, so the legend reads them
    createHudThread()
end

-- Sends the readout to the page when it changes: often while the thrusters work or the car flies, rarely otherwise
function createHudThread()
    CreateThread(function()
        local sent = nil
        while true do
            local state = getHudState()
            local encoded = state and json.encode(state) or "false"
            if encoded ~= sent then
                SendNUIMessage({ hud = state or false })
                sent = encoded
            end
            if not state and isPanelOpen then
                closePanel()        -- The player left the vehicle
            end
            Wait(state and state.active and HUD_ACTIVE_INTERVAL or HUD_IDLE_INTERVAL)
        end
    end)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Functions
-----------------------------------------------------------------------------------------------------------------------------------------

-- A flight assist works when the server allows it (Config.Flight) and the driver didn't turn it off on the panel
function isAssistOn(key)
    return Config.Flight[key] == true and playerSettings[key] ~= false
end

-- The driver's corner for the readout, or the server's default
function getHudPosition()
    if HUD_POSITIONS[playerSettings.hudPosition] then
        return playerSettings.hudPosition
    end
    return Config.Interface.hudPosition
end

function setHudVisible(visible)
    playerSettings.hudHidden = not visible
    saveSettings()
    SendNUIMessage({ hudVisible = visible })
end

function saveSettings()
    SetResourceKvp(SETTINGS_KVP, json.encode(playerSettings))
end

-- Everything the readout and the panel show, or nil when the player isn't driving a car with thrusters
function getHudState()
    local vehicle = currentVehicle
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil
    end

    local throttles = {}
    local firing = false
    for index = 1, #NOZZLES do
        local throttle = nozzleThrottles[index] or 0.0
        throttles[index] = math.floor(throttle * 10 + 0.5) / 10
        firing = firing or throttle > 0
    end

    local inAir = IsEntityInAir(vehicle)
    local state = {
        tank = math.floor(tankLevel / Config.Tank.capacity * 1000 + 0.5) / 10,
        throttles = throttles,
        inAir = inAir,
        fan = isSuctionOn == true,
        stabilityControl = isAssistOn("stabilityControl"),
        landingAssist = isAssistOn("landingAssist"),
        stunts = isAssistOn("stunts"),
        active = firing or inAir,
    }
    if Config.Boost.enabled then
        updateBoostCharge()
        state.boost = math.floor(boostCharge * 100)
        state.overheated = boostOverheated
    end
    if Config.Flight.enabled then
        state.climb = math.floor(getClimbRemaining() * 100)
    end
    if inAir then
        local distance = getGroundDistance(vehicle, ALTITUDE_RANGE)
        if distance then
            local min = GetModelDimensions(GetEntityModel(vehicle))
            state.altitude = math.floor(math.max(0.0, distance + min.z) * 10 + 0.5) / 10
        end
        state.verticalSpeed = math.floor(GetEntityVelocity(vehicle).z * 10 + 0.5) / 10
    end
    return state
end

-- Sends the page lc_utils' config and translations (its own texts are in nui/lang) and waits until it has loaded them. The readout needs
-- them as soon as the player joins, so they're sent again until the page answers
function loadNuiVariables()
    local waited = 0
    while not isNuiVariablesLoaded do
        if waited % NUI_RESEND_INTERVAL == 0 then
            SendNUIMessage({
                utils = { config = Utils.Config, lang = Utils.Lang },
                resourceName = GetCurrentResourceName()
            })
        end
        if waited == NUI_TIMEOUT then
            print("Error: Timeout while loading NUI variables after " .. NUI_TIMEOUT .. " ms. Still trying.")
        end
        Wait(100)
        waited = waited + 100
    end
end

-- What the page needs once: default keys, the features the server enabled and the nozzle layout for the car diagram
function getUiSetup()
    local nozzles = {}
    for index, nozzle in ipairs(NOZZLES) do
        nozzles[index] = { group = nozzle.group, x = nozzle.position.x, y = nozzle.position.y, ex = nozzle.exhaust.x, ey = nozzle.exhaust.y }
    end
    return {
        hud = Config.Interface.hud,
        hudVisible = playerSettings.hudHidden ~= true,
        hudPosition = getHudPosition(),
        reserve = getTankReserve() / Config.Tank.capacity * 100,
        nozzles = nozzles,
        keys = getBoundKeys(),
        features = {
            boost = Config.Boost.enabled,
            flight = Config.Flight.enabled,
            fan = Config.Suction.enabled,
            stabilityControl = Config.Flight.enabled and Config.Flight.stabilityControl,
            landingAssist = Config.Flight.enabled and Config.Flight.landingAssist,
            stunts = Config.Flight.enabled and Config.Flight.stunts,
        },
    }
end

-- The keys the player bound the commands to in the FiveM settings. The game names a key with text as "t_<key>" and shows the others
-- (Shift, Space, Ctrl...) as icons, which the page can't draw: for those the default key from the config is shown
function getBoundKeys()
    local defaults = {
        boost = Config.Boost.key,
        lift = Config.Flight.key,
        fan = Config.Suction.key,
        panel = Config.Interface.panelKey,
        hud = Config.Interface.hudKey,
    }
    local keys = {}
    for name, command in pairs(KEY_COMMANDS) do
        local button = GetControlInstructionalButton(0, GetHashKey(command) | 0x80000000, true)
        if type(button) == "string" and button:sub(1, 2) == "t_" then
            keys[name] = button:sub(3)
        else
            keys[name] = defaults[name]
        end
    end
    return keys
end

function togglePanel()
    if isPanelOpen then
        closePanel()
    elseif currentVehicle ~= 0 and not IsPauseMenuActive() then
        openPanel()
    end
end

function openPanel()
    local model = GetEntityModel(currentVehicle)
    local name = GetLabelText(GetDisplayNameFromVehicleModel(model))
    if name == "NULL" then
        name = GetDisplayNameFromVehicleModel(model)
    end
    isPanelOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ panel = { open = true, vehicle = name, plate = GetVehicleNumberPlateText(currentVehicle), keys = getBoundKeys() } })
end

function closePanel()
    isPanelOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ panel = { open = false } })
end

RegisterNUICallback('post', function(body, cb)
    local data = body.data or {}
    if body.event == "close" then
        closePanel()
    elseif body.event == "setAssist" then
        if ASSISTS[data.key] and type(data.value) == "boolean" then
            playerSettings[data.key] = data.value
            saveSettings()
        end
    elseif body.event == "setHudVisible" then
        if type(data.value) == "boolean" then
            setHudVisible(data.value)
        end
    elseif body.event == "setHudPosition" then
        if HUD_POSITIONS[data.value] then
            playerSettings.hudPosition = data.value
            saveSettings()
        end
    elseif body.event == "setFan" then
        if Config.Suction.enabled and currentVehicle ~= 0 and type(data.value) == "boolean" and (isSuctionOn == true) ~= data.value then
            toggleSuction()
        end
    end
    cb(200)
end)

RegisterNUICallback('setNuiVariablesLoaded', function(body, cb)
    isNuiVariablesLoaded = true
    cb(200)
end)
