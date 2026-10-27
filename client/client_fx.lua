-- Thruster plumes and sounds for every player near the vehicle. The driver's client reports which thrusters work through a server
-- event, the server keeps them in the vehicle state 'thrusterFx' (bit n-1 = nozzle n of NOZZLES is firing, bit 15 = suction fan)
-- and every client shows that state. A client could write the state of a car it owns, so a value that isn't a valid mask shows nothing

-- Do not load anything here if the effects are disabled
if not Config.Effects.enabled then
    return
end

local FX_SUCTION = 1 << 15
local MAX_FX_MASK = 0xFFFF      -- Room for 15 nozzles and the fan
local NOZZLE_COUNT = #NOZZLES

local REPORT_INTERVAL = 50      -- ms between checks of the thrusters the driver uses
local RESEND_INTERVAL = 250     -- ms before reporting again while the vehicle state differs (the server drops too frequent changes)
local SCAN_INTERVAL = 1000      -- ms between checks for vehicles coming into scope with thrusters working
local SOUND_INTERVAL = 100      -- ms between sound updates sent to the NUI page
local GROUND_SMOKE_INTERVAL = 150   -- ms between updates of the smoke on the ground under each vehicle
local SOUND_RANGE = 80.0        -- m from the camera within which the thrusters are heard
local FAN_VOLUME_SHARE = 0.6    -- Fan volume, as a share of Config.Effects.volume
local MIN_PLUME_THROTTLE = 0.15 -- A nozzle shows its plume from this throttle

-- Plume of each nozzle group: every particle listed is layered on each firing nozzle (a jet and a thick smoke). A particle name that
-- doesn't exist is reported in F8
local PLUME_PARTICLES = {
    rear = {
        { asset = "core", particle = "ent_sht_steam", scale = 3.6 },
        { asset = "core", particle = "exp_grd_bzgas_smoke", scale = 2.5 },
    },
    lift = {
        { asset = "core", particle = "ent_sht_steam", scale = 4.0 },
        { asset = "core", particle = "exp_grd_bzgas_smoke", scale = 2.6 },
    },
    side = {
        { asset = "core", particle = "ent_sht_steam", scale = 3.2 },
        { asset = "core", particle = "exp_grd_bzgas_smoke", scale = 2.3 },
    },
}

-- Smoke blown on the ground under the car while the lift fires near it, bigger the lower the car is
local GROUND_SMOKE = {
    asset = "core",
    particle = "exp_grd_bzgas_smoke",
    scale = 5.0,                -- Size with the car on the ground
    maxHeight = 8.0,            -- m above the ground from which it shows
}

-- Bits of the lift nozzles, which blow smoke on the ground
local LIFT_MASK = 0
for index, nozzle in ipairs(NOZZLES) do
    if nozzle.group == "lift" then
        LIFT_MASK = LIFT_MASK | (1 << (index - 1))
    end
end

local shownVehicles = {}        -- [vehicle] = { mask = shown effects, plumes = { [nozzle index] = { particle handles } }, groundSmoke = handle }
local loadedAssets = {}         -- [asset] = true once the particle asset is loaded
local warnedParticles = {}      -- [particle] = true once reported as not found

-----------------------------------------------------------------------------------------------------------------------------------------
-- Threads
-----------------------------------------------------------------------------------------------------------------------------------------

function createEffectsThreads()
    loadParticleAssets()
    -- Listens once the particles are loaded, so no plume is skipped. Vehicles that changed before are caught by the scan
    AddStateBagChangeHandler('thrusterFx', nil, onFxStateChange)
    createFxReportThread()
    createFxScanThread()
    if Config.Effects.groundSmoke then
        createGroundSmokeThread()
    end
    if Config.Effects.volume > 0 then
        createFxSoundThread()
    end
end

-- Driver: shows its own thrusters at once (without waiting for the server) and reports them. A change is sent at once, and sent again
-- while the vehicle state still differs, so a report the server dropped is not lost
function createFxReportThread()
    CreateThread(function()
        local reportedVehicle = 0
        local reportedMask = 0
        local reportedAt = 0
        while true do
            local vehicle = currentVehicle
            if reportedVehicle ~= 0 and reportedVehicle ~= vehicle then
                -- The player left the vehicle: turn its effects off. From now on it shows the vehicle state like any other
                if DoesEntityExist(reportedVehicle) then
                    if reportedMask ~= 0 then
                        TriggerServerEvent("lc_thrusters:setFx", VehToNet(reportedVehicle), 0)
                    end
                    applyFx(reportedVehicle, 0)
                end
                reportedVehicle = 0
                reportedMask = 0
            end

            if vehicle ~= 0 and DoesEntityExist(vehicle) then
                reportedVehicle = vehicle
                local mask = getCurrentFxMask()
                local shown = shownVehicles[vehicle]
                if mask ~= (shown and shown.mask or 0) then
                    applyFx(vehicle, mask)
                end
                local now = GetGameTimer()
                -- The vehicle state is only read when a resend may be due
                if mask ~= reportedMask or (now - reportedAt >= RESEND_INTERVAL and mask ~= validFxMask(Entity(vehicle).state.thrusterFx)) then
                    TriggerServerEvent("lc_thrusters:setFx", VehToNet(vehicle), mask)
                    reportedMask = mask
                    reportedAt = now
                end
                Wait(REPORT_INTERVAL)
            else
                Wait(500)
            end
        end
    end)
end

-- Every client: shows the effects of the vehicles that come into scope with thrusters working, and forgets deleted vehicles. Only
-- vehicles new since the last scan are read: changes of the ones already here come through the state listener
function createFxScanThread()
    CreateThread(function()
        local knownVehicles = {}
        while true do
            for vehicle in pairs(shownVehicles) do
                if not DoesEntityExist(vehicle) then
                    shownVehicles[vehicle] = nil     -- Its plumes went with it
                end
            end
            local streamedVehicles = {}
            for _, vehicle in ipairs(GetGamePool('CVehicle')) do
                streamedVehicles[vehicle] = true
                if not knownVehicles[vehicle] and vehicle ~= currentVehicle and NetworkGetEntityIsNetworked(vehicle) then
                    local mask = validFxMask(Entity(vehicle).state.thrusterFx)
                    if mask ~= 0 then
                        applyFx(vehicle, mask)
                    end
                end
            end
            knownVehicles = streamedVehicles
            Wait(SCAN_INTERVAL)
        end
    end)
end

-- Every client: sends the NUI page the volume and pan of each vehicle to hear. The sound is generated there (nui/panel.js)
function createFxSoundThread()
    CreateThread(function()
        local wasPlaying = false
        while true do
            -- Nothing shown and nothing left to fade out: no work until a vehicle shows its thrusters
            if next(shownVehicles) ~= nil or wasPlaying then
                local playing = updateSounds()
                -- One empty update after the last sound lets the page fade it out
                if not playing and wasPlaying then
                    SendNUIMessage({ sounds = {} })
                end
                wasPlaying = playing
            end
            Wait(SOUND_INTERVAL)
        end
    end)
end

-- Sends the NUI page the volume and pan of each shown vehicle within range. Returns whether any is heard
function updateSounds()
    local range = SOUND_RANGE
    local sounds = {}
    local playing = false
    local camera = GetFinalRenderedCamCoord()
    local heading = math.rad(GetFinalRenderedCamRot(2).z)
    for vehicle, shown in pairs(shownVehicles) do
        if DoesEntityExist(vehicle) then
            local offset = GetEntityCoords(vehicle) - camera
            local distance = #offset
            if distance < range then
                local falloff = (1.0 - distance / range) ^ 2
                -- The camera's right is (cos h, sin h) in GTA's heading convention (forward is (-sin h, cos h))
                local pan = 0.0
                if distance > 0.1 then
                    pan = (offset.x * math.cos(heading) + offset.y * math.sin(heading)) / distance
                end
                -- Louder with more nozzles firing, a single one still clearly heard
                local firing = countFiringNozzles(shown.mask)
                sounds[tostring(vehicle)] = {
                    thrust = Config.Effects.volume * falloff * math.sqrt(firing / NOZZLE_COUNT),
                    fan = (shown.mask & FX_SUCTION) ~= 0 and Config.Effects.volume * FAN_VOLUME_SHARE * falloff or 0.0,
                    pan = pan,
                }
                playing = true
            end
        end
    end
    if playing then
        SendNUIMessage({ sounds = sounds })
    end
    return playing
end

-- Every client: blows smoke on the ground under the vehicles whose lift fires near it, stronger the lower they are
function createGroundSmokeThread()
    CreateThread(function()
        local maxHeight = GROUND_SMOKE.maxHeight
        while true do
            for vehicle, shown in pairs(shownVehicles) do
                local distance = nil
                if (shown.mask & LIFT_MASK) ~= 0 and DoesEntityExist(vehicle) then
                    distance = getGroundDistance(vehicle, maxHeight)
                end
                setGroundSmoke(vehicle, shown, distance)
            end
            Wait(GROUND_SMOKE_INTERVAL)
        end
    end)
end

-----------------------------------------------------------------------------------------------------------------------------------------
-- Functions
-----------------------------------------------------------------------------------------------------------------------------------------

function onFxStateChange(bagName, key, value)
    local vehicle = GetEntityFromStateBagName(bagName)
    if vehicle == 0 or vehicle == currentVehicle then
        return      -- Not streamed to this client (too far away to be seen), or the player's own vehicle (shown by the report thread)
    end
    applyFx(vehicle, validFxMask(value))
end

function getCurrentFxMask()
    local mask = 0
    for index, throttle in pairs(nozzleThrottles) do
        if throttle >= MIN_PLUME_THROTTLE then
            mask = mask | (1 << (index - 1))
        end
    end
    if isSuctionOn then
        mask = mask | FX_SUCTION
    end
    return mask
end

function validFxMask(value)
    if math.type(value) == "integer" and value >= 0 and value <= MAX_FX_MASK then
        return value
    end
    return 0
end

function countFiringNozzles(mask)
    local count = 0
    for index = 1, NOZZLE_COUNT do
        if (mask & (1 << (index - 1))) ~= 0 then
            count = count + 1
        end
    end
    return count
end

function applyFx(vehicle, mask)
    local shown = shownVehicles[vehicle]
    if not shown then
        if mask == 0 then
            return
        end
        shown = { mask = 0, plumes = {} }
        shownVehicles[vehicle] = shown
    end
    for index = 1, NOZZLE_COUNT do
        setPlume(vehicle, shown, index, (mask & (1 << (index - 1))) ~= 0)
    end
    shown.mask = mask
    if mask == 0 then
        setGroundSmoke(vehicle, shown, nil)
        shownVehicles[vehicle] = nil
    end
end

-- Starts or stops the plume of one nozzle: every particle layer of its group, at the nozzle's position on this vehicle and pointing out
-- with its exhaust
function setPlume(vehicle, shown, index, on)
    local handles = shown.plumes[index]
    if on and not handles then
        local nozzle = NOZZLES[index]
        local offset = getNozzleOffset(vehicle, nozzle)
        handles = {}
        for _, layer in ipairs(PLUME_PARTICLES[nozzle.group] or {}) do
            handles[#handles + 1] = startLoopedParticle(layer, vehicle, offset, nozzle.plumeRotation, layer.scale)
        end
        shown.plumes[index] = handles
    elseif not on and handles then
        for _, handle in ipairs(handles) do
            stopLoopedParticle(handle)
        end
        shown.plumes[index] = nil
    end
end

-- Starts, moves or stops the smoke on the ground under a vehicle. distance: from the vehicle down to the ground (nil: no smoke)
function setGroundSmoke(vehicle, shown, distance)
    local settings = GROUND_SMOKE
    if not distance or distance > settings.maxHeight then
        if shown.groundSmoke then
            stopLoopedParticle(shown.groundSmoke)
            shown.groundSmoke = nil
        end
        return
    end
    local scale = settings.scale * (1.0 - distance / settings.maxHeight)
    if shown.groundSmoke then
        SetParticleFxLoopedOffsets(shown.groundSmoke, 0.0, 0.0, -distance, 0.0, 0.0, 0.0)
        SetParticleFxLoopedScale(shown.groundSmoke, scale)
    else
        shown.groundSmoke = startLoopedParticle(settings, vehicle, vector3(0.0, 0.0, -distance), vector3(0.0, 0.0, 0.0), scale)
    end
end

-- Starts a looped particle on a vehicle (offset and rotation in its frame), or nil if its asset isn't loaded or it doesn't exist.
-- A name that doesn't exist is reported once in F8
function startLoopedParticle(settings, vehicle, offset, rotation, scale)
    if not loadedAssets[settings.asset] then
        return nil
    end
    UseParticleFxAssetNextCall(settings.asset)
    local handle = StartParticleFxLoopedOnEntity(settings.particle, vehicle, offset.x, offset.y, offset.z, rotation.x, rotation.y, rotation.z,
        scale, false, false, false)
    if handle == 0 or not DoesParticleFxLoopedExist(handle) then
        if not warnedParticles[settings.particle] then
            print(("[lc_thrusters] Particle '%s' wasn't found in asset '%s', change it in client_fx.lua"):format(settings.particle, settings.asset))
            warnedParticles[settings.particle] = true
        end
        return nil
    end
    return handle
end

function stopLoopedParticle(handle)
    if DoesParticleFxLoopedExist(handle) then
        StopParticleFxLooped(handle, false)
    end
end

function loadParticleAssets()
    local assets = { [GROUND_SMOKE.asset] = true }
    for _, layers in pairs(PLUME_PARTICLES) do
        for _, layer in ipairs(layers) do
            assets[layer.asset] = true
        end
    end
    for asset in pairs(assets) do
        RequestNamedPtfxAsset(asset)
        local timeout = GetGameTimer() + 5000
        while not HasNamedPtfxAssetLoaded(asset) and GetGameTimer() < timeout do
            Wait(10)
        end
        if HasNamedPtfxAssetLoaded(asset) then
            loadedAssets[asset] = true
        else
            print(("[lc_thrusters] Particle asset '%s' could not be loaded, its effects won't show"):format(asset))
        end
    end
end
