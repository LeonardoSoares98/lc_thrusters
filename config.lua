Config = {}

-- Vehicles that come with the thruster package installed (spawn name)
Config.Vehicles = {
    ["raiden"] = true,
    ["virtue"] = true,
}

-- Optional database. On: admins (and other scripts, through the exports) install the package on single vehicles by plate, on top of
-- Config.Vehicles, and the tank level of installed and player-owned vehicles is saved, so a respawned car keeps it.
-- Off: only Config.Vehicles have the package and every tank starts full after a restart
Config.Database = {
    enabled = false,
    installCommand = "thrusters_install",   -- Installs the package on the vehicle the admin sits in (ACE permission "command.thrusters_install")
    removeCommand = "thrusters_remove",     -- Removes it (ACE permission "command.thrusters_remove")
}

-- Compressed air tank, shared by every thruster
Config.Tank = {
    capacity = 50.0,           -- Tank size
    rechargeRate = 1.0,         -- Refilled per second by the onboard compressor while someone drives the vehicle
}

-- Rear thrusters: push the car forward while the key is held
Config.Boost = {
    enabled = true,
    key = "LSHIFT",             -- Default keybind (players can rebind it in GTA settings > Key Bindings > FiveM)
    maxSpeed = 350.0,           -- km/h above which the boost stops pushing
    maxDuration = 1000,         -- ms of firing before it overheats
    cooldown = 3000,            -- ms to cool down from empty. Overheated, it's locked until fully cooled
}

-- Lift and flight assists
Config.Flight = {
    enabled = true,
    key = "SPACE",              -- Default keybind, hold it to climb
    climbSpeed = 6.0,           -- m/s upward while the key is held
    maxClimbTime = 2000,        -- ms of climbing per flight (resets when the car is back on the ground)
    stabilityControl = true,    -- In every jump: keeps the car level and pointing where it travels. Off: only in flights started with the key
    landingAssist = true,       -- Falling: free fall, then a late burn for a soft touchdown
    stunts = true,              -- In the air, A/D roll and W/S pitch the car with the thrusters (kickflips, flips)
}

-- Underbody fan: sucks the car to the road, so it can hold banked, vertical and upside-down track
Config.Suction = {
    enabled = true,
    key = "LCONTROL",           -- Default keybind, press to toggle the fan
}

-- Car screen: a readout of the thrusters while driving, and a control panel where each driver turns the assists and the fan on or off
-- (their choices are remembered)
Config.Interface = {
    hud = true,                 -- Readout of the thrusters while driving a car with the package (each driver can hide it)
    hudPosition = "bottom-right", -- Default corner of the readout: "top-left", "top-right", "bottom-left" or "bottom-right" (drivers can move it)
    hudKey = "F9",              -- Default keybind to hide or show the readout (F8 is FiveM's console)
    panelKey = "F7",            -- Default keybind to open the control panel
}

-- Thruster plumes and sounds, seen and heard by every player near the vehicle
Config.Effects = {
    enabled = true,
    groundSmoke = true,         -- Smoke on the ground under the car while it lifts near it
    volume = 0.5,               -- Thruster sound volume (0..1, 0 = no sound)
}
