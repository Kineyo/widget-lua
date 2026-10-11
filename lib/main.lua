#!/usr/bin/env lua
----------------------------------------------------------------------
-- main.lua  –  Qwen-Widget entry point
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Determine base directory (from environment or fallback)
----------------------------------------------------------------------
local script_source = debug.getinfo(1, "S").source:match("^@?(.*)$")
local script_dir = script_source and script_source:match("(.*)/[^/]+")
local detected_base = nil
if script_dir then
    detected_base = script_dir:match("(.*)/lib") or script_dir
end
local base_dir = os.getenv("QWEN_WIDGET_DIR") or detected_base or "/opt/qwen-widget"
local lib_dir  = base_dir .. "/lib"

-- Add lib directory to package.path (LUA_PATH from launcher already
-- includes LGI system paths; here we prepend our own lib dir)
package.path = lib_dir .. "/?.lua;" .. package.path

----------------------------------------------------------------------
-- Load LGI first to validate it works
----------------------------------------------------------------------
local ok, lgi = pcall(require, "lgi")
if not ok then
    io.stderr:write("[qwen-widget] FATAL: cannot load LGI bindings.\n")
    io.stderr:write("  Ensure lua-lgi is installed and LUA_PATH/LUA_CPATH are set.\n")
    io.stderr:write("  Error: " .. tostring(lgi) .. "\n")
    os.exit(1)
end

local Gtk  = lgi.require("Gtk", "3.0")
local GLib = lgi.GLib

----------------------------------------------------------------------
-- Load configuration and override paths
----------------------------------------------------------------------
local config = require("config")
config.BASE_DIR   = base_dir
config.ASSETS_DIR = base_dir .. "/assets"
config.AVATAR     = config.ASSETS_DIR .. "/avatar.jpg"

----------------------------------------------------------------------
-- Load widget (which loads everything else)
----------------------------------------------------------------------
local widget = require("widget")

----------------------------------------------------------------------
-- Initialise GTK
----------------------------------------------------------------------
Gtk.init()

----------------------------------------------------------------------
-- Build and start
----------------------------------------------------------------------
io.stderr:write("[qwen-widget] Starting... (model=" .. config.OLLAMA_MODEL .. ")\n")
io.stderr:write("[qwen-widget] Base dir: " .. base_dir .. "\n")
io.stderr:write("[qwen-widget] Avatar: " .. config.AVATAR .. "\n")

widget.build()
widget.start()

----------------------------------------------------------------------
-- Run GTK main loop (blocks here)
----------------------------------------------------------------------
io.stderr:write("[qwen-widget] Running (minimalist). Left-click=Chat AI, Right-click/Scroll=Burbuja de datos, Middle-click=Player.\n")
Gtk.main()

io.stderr:write("[qwen-widget] Exited cleanly.\n")
