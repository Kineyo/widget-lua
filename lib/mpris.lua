----------------------------------------------------------------------
-- mpris.lua  –  MPRIS2 Media Player client & listener for Qwen-Widget
--               Specialized for YouTube Music, Chromium, Spotify, etc.
----------------------------------------------------------------------
local lgi       = require("lgi")
local Gio       = lgi.Gio
local GLib      = lgi.GLib
local GdkPixbuf = lgi.GdkPixbuf

local config    = require("config")
local utils     = require("utils")

local mpris = {}

-- Current media state
mpris.track = {
    title       = "",
    artist      = "",
    album       = "",
    art_url     = "",
    art_pixbuf  = nil,
    length      = 0,      -- seconds
    position    = 0,      -- seconds
    status      = "Stopped", -- Playing, Paused, Stopped
    player_bus  = nil,
    player_name = "YouTube Music",
}

mpris.active_bus   = nil
mpris.is_seeking   = false -- flag to avoid ticker overwrite during drag
mpris.ticker_id    = nil
local last_track_key = ""

-- Callbacks
mpris.on_track_change   = nil -- function(track)
mpris.on_status_change  = nil -- function(status)
mpris.on_position_tick  = nil -- function(pos, length)
mpris.track_listeners    = {}
mpris.position_listeners = {}
mpris.status_listeners   = {}

function mpris.add_track_listener(fn)
    table.insert(mpris.track_listeners, fn)
end

function mpris.add_position_listener(fn)
    table.insert(mpris.position_listeners, fn)
end

function mpris.add_status_listener(fn)
    table.insert(mpris.status_listeners, fn)
end

function mpris.notify_position(pos, len)
    if mpris.on_position_tick then
        pcall(mpris.on_position_tick, pos, len)
    end
    for _, fn in ipairs(mpris.position_listeners) do
        pcall(fn, pos, len)
    end
end

local bus = nil

----------------------------------------------------------------------
-- Helper: Format seconds to MM:SS
----------------------------------------------------------------------
function mpris.format_time(sec)
    if not sec or sec < 0 or sec ~= sec then sec = 0 end
    sec = math.floor(sec)
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%02d:%02d", m, s)
end

----------------------------------------------------------------------
-- Helper: Asynchronous command execution
----------------------------------------------------------------------
local function exec_async(argv, callback)
    local ok, sub = pcall(Gio.Subprocess.new, argv,
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE)
    if ok and sub then
        sub:communicate_utf8_async(nil, nil, function(s, res)
            local ok_finish, stdout, stderr = pcall(function() return s:communicate_utf8_finish(res) end)
            if callback and ok_finish and stdout and type(stdout) == "string" then
                callback(stdout)
            end
        end)
    end
end

----------------------------------------------------------------------
-- Load artwork (local file or download remote URL)
----------------------------------------------------------------------
local function load_artwork(art_url)
    if not art_url or #art_url == 0 then
        mpris.track.art_pixbuf = nil
        if mpris.on_art_loaded then mpris.on_art_loaded(nil) end
        return
    end

    local size = config.PLAYER_COVER_SIZE or 68

    if art_url:find("^file://") then
        local local_path = art_url:gsub("^file://", "")
        -- URL-decode spaces if any (%20)
        local_path = local_path:gsub("%%20", " ")
        local ok, pb = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale, local_path, size, size, true)
        if ok and pb then
            mpris.track.art_pixbuf = pb
            if mpris.on_art_loaded then mpris.on_art_loaded(pb) end
            return
        end
    elseif art_url:find("^https?://") then
        -- Download with curl asynchronously to a temporary cache file
        local tmp_file = "/tmp/qwen_widget_album_art.jpg"
        exec_async({"curl", "-sL", "-m", "10", art_url, "-o", tmp_file}, function()
            local ok, pb = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale, tmp_file, size, size, true)
            if ok and pb then
                mpris.track.art_pixbuf = pb
                if mpris.on_art_loaded then mpris.on_art_loaded(pb) end
            end
        end)
        return
    end

    mpris.track.art_pixbuf = nil
    if mpris.on_art_loaded then mpris.on_art_loaded(nil) end
end

----------------------------------------------------------------------
-- Find active MPRIS player on DBus
----------------------------------------------------------------------
local function find_mpris_players()
    if not bus then return {} end
    local ok, res = pcall(function()
        return bus:call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            nil,
            GLib.VariantType("(as)"),
            Gio.DBusCallFlags.NONE,
            1000, nil)
    end)
    if not ok or not res then return {} end

    local names = res.value[1] or {}
    local candidates = {}
    for i = 1, #names do
        local n = names[i]
        if n:find("^org%.mpris%.MediaPlayer2%.") then
            candidates[#candidates+1] = n
        end
    end
    return candidates
end

local function select_active_player()
    local players = find_mpris_players()
    if #players == 0 then
        mpris.active_bus = nil
        return nil
    end

    -- Prioritize YouTube Music / Chromium / desktop app
    for _, p in ipairs(players) do
        local pl = p:lower()
        if pl:find("youtube") or pl:find("chromium") then
            mpris.active_bus = p
            return p
        end
    end

    -- Otherwise take the first available player
    mpris.active_bus = players[1]
    return mpris.active_bus
end

local function split_by_delim(str, delim)
    local result = {}
    local start = 1
    while true do
        local pos = str:find(delim, start, true)
        if not pos then
            result[#result+1] = str:sub(start)
            break
        end
        result[#result+1] = str:sub(start, pos - 1)
        start = pos + #delim
    end
    return result
end

----------------------------------------------------------------------
-- Refresh current player metadata from DBus
----------------------------------------------------------------------
function mpris.refresh()
    exec_async({"playerctl", "-p", "chromium,google-chrome,youtube-music,spotify,%any", "metadata", "--format", "{{title}};;;{{artist}};;;{{album}};;;{{mpris:artUrl}};;;{{mpris:length}};;;{{status}}"}, function(out)
        if out and #out > 0 then
            local clean_out = out:gsub("[\r\n]+$", "")
            local parts = split_by_delim(clean_out, ";;;")
            if #parts >= 6 then
                local title = parts[1] or ""
                local artist = parts[2] or ""
                local album = parts[3] or ""
                local art_url = parts[4] or ""
                local len_us = tonumber(parts[5]) or 0
                local status = parts[6] or "Stopped"

                -- Trim whitespace
                title = title:gsub("^%s+", ""):gsub("%s+$", "")
                artist = artist:gsub("^%s+", ""):gsub("%s+$", "")

                -- Fallback: If artist is empty but title has "Artist - Song"
                if #artist == 0 and title:find(" %- ") then
                    local a, t = title:match("^(.-) %- (.*)$")
                    if a and t then
                        artist = a
                        title = t
                    end
                end

                local length_sec = len_us / 1000000
                local key = title .. "|" .. artist .. "|" .. art_url
                local changed = (key ~= last_track_key and #title > 0)
                last_track_key = key

                local old_status = mpris.track.status
                mpris.track.title   = title
                mpris.track.artist  = artist
                mpris.track.album   = album
                mpris.track.art_url = art_url
                mpris.track.length  = length_sec
                mpris.track.status  = status

                load_artwork(art_url)

                if changed then
                    if mpris.on_track_change then
                        pcall(mpris.on_track_change, mpris.track)
                    end
                    for _, fn in ipairs(mpris.track_listeners) do
                        pcall(fn, mpris.track)
                    end
                end

                if old_status ~= status then
                    if mpris.on_status_change then
                        pcall(mpris.on_status_change, status)
                    end
                    for _, fn in ipairs(mpris.status_listeners) do
                        pcall(fn, status)
                    end
                end
                return
            end
        end

        -- If playerctl returned nothing, check DBus active player
        if bus and mpris.active_bus then
            local ok, res = pcall(function()
                return bus:call_sync(
                    mpris.active_bus,
                    "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties",
                    "GetAll",
                    GLib.Variant("(s)", { "org.mpris.MediaPlayer2.Player" }),
                    GLib.VariantType("(a{sv})"),
                    Gio.DBusCallFlags.NONE,
                    1000, nil)
            end)
            if ok and res and res.value and res.value[1] then
                local props = res.value[1]
                mpris.track.status = props["PlaybackStatus"] or "Stopped"
            end
        end
    end)
end

----------------------------------------------------------------------
-- Query precise position from player
----------------------------------------------------------------------
function mpris.get_position()
    if mpris.is_seeking then return mpris.track.position end
    if not bus then return mpris.track.position end
    local dest = mpris.active_bus or select_active_player()
    if not dest then return mpris.track.position end

    local ok, res = pcall(function()
        return bus:call_sync(
            dest,
            "/org/mpris/MediaPlayer2",
            "org.freedesktop.DBus.Properties",
            "Get",
            GLib.Variant("(ss)", { "org.mpris.MediaPlayer2.Player", "Position" }),
            GLib.VariantType("(v)"),
            Gio.DBusCallFlags.NONE,
            500, nil)
    end)

    if ok and res and res.value and res.value[1] then
        local raw = res.value[1].value
        if type(raw) == "number" then
            mpris.track.position = raw / 1000000
        end
    end
    return mpris.track.position
end

----------------------------------------------------------------------
-- Controls
----------------------------------------------------------------------
function mpris.play_pause()
    exec_async({"playerctl", "play-pause"}, function()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 150, function()
            mpris.refresh()
            return false
        end)
    end)
end

function mpris.next()
    exec_async({"playerctl", "next"}, function()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, function()
            mpris.refresh()
            return false
        end)
    end)
end

function mpris.previous()
    exec_async({"playerctl", "previous"}, function()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, function()
            mpris.refresh()
            return false
        end)
    end)
end

function mpris.seek(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    mpris.track.position = seconds
    mpris.is_seeking = true
    mpris.notify_position(mpris.track.position, mpris.track.length)

    -- Use playerctl position to seek directly in seconds
    exec_async({"playerctl", "position", string.format("%.2f", seconds)}, function()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, function()
            mpris.is_seeking = false
            return false
        end)
    end)
end

----------------------------------------------------------------------
-- Start MPRIS Listener & Ticker
----------------------------------------------------------------------
function mpris.start()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    if not bus then
        io.stderr:write("[qwen-widget] WARN: cannot connect DBus session for MPRIS\n")
        return
    end

    select_active_player()
    mpris.refresh()

    -- 1) Subscribe to PropertiesChanged on /org/mpris/MediaPlayer2
    bus:signal_subscribe(
        nil,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        "/org/mpris/MediaPlayer2",
        nil,
        Gio.DBusSignalFlags.NONE,
        function(conn, sender, path, iface, signal, params)
            local ok = pcall(function()
                if params and params.value and params.value[1] == "org.mpris.MediaPlayer2.Player" then
                    mpris.refresh()
                end
            end)
        end)

    -- 2) Subscribe to NameOwnerChanged to detect players opening/closing
    bus:signal_subscribe(
        "org.freedesktop.DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "/org/freedesktop/DBus",
        nil,
        Gio.DBusSignalFlags.NONE,
        function(conn, sender, path, iface, signal, params)
            pcall(function()
                local name = params.value[1]
                if name and name:find("^org%.mpris%.MediaPlayer2%.") then
                    select_active_player()
                    mpris.refresh()
                end
            end)
        end)

    -- 3) Smooth position ticker
    local tick_interval = config.PLAYER_UPDATE_MS or 250
    local step_sec = tick_interval / 1000
    local sync_counter = 0

    mpris.ticker_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, tick_interval, function()
        if mpris.track.status == "Playing" and not mpris.is_seeking then
            sync_counter = sync_counter + 1
            if sync_counter >= 8 then
                -- Periodically sync exact position from DBus (every 2 seconds)
                sync_counter = 0
                mpris.get_position()
            else
                mpris.track.position = mpris.track.position + step_sec
                if mpris.track.length > 0 and mpris.track.position > mpris.track.length then
                    mpris.track.position = mpris.track.length
                end
            end

            mpris.notify_position(mpris.track.position, mpris.track.length)
        end
        return true -- keep timer
    end)
end

return mpris
