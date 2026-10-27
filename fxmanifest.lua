fx_version 'cerulean'
game 'gta5'
author 'LixeiroCharmoso'
name 'lc_thrusters'

ui_page "nui/ui.html"

lua54 'yes'

escrow_ignore {
	'**'
}

client_scripts {
	"client/client.lua",
	"client/client_thrusters.lua",
	"client/client_boost.lua",
	"client/client_flight.lua",
	"client/client_suction.lua",
	"client/client_fx.lua",
	"client/client_ui.lua",
}

server_scripts {
	"@mysql-async/lib/MySQL.lua",
	"server/server.lua",
}

shared_scripts {
	"lang/*.lua",
	"config.lua",
	"@lc_utils/functions/loader.lua",
}

files {
	"version",
	"nui/lang/*",
	"nui/ui.html",
	"nui/panel.js",
	"nui/css/*",
	"nui/images/*",
}

dependency "lc_utils"
