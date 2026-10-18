----------------------------------------------------------------------
-- mpris.lua  –  Native C/C++ MPRIS2 Media Client (YouTube Music + Spotify)
--               Uses qwen_native GDBus IPC for zero-blocking real-time sync
----------------------------------------------------------------------
local lgi       = require("lgi")
local Gio       = lgi.Gio
local GLib      = lgi.GLib
local GdkPixbuf = lgi.GdkPixbuf

local config    = require("config")
local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local mpris = {}

mpris.track = {
    title       = "",
    artist      = "",
    album       = "",
    art_url     = "",
    art_pixbuf  = nil,
    length      = 0,
    position    = 0,
    volume      = 1.0,
    status      = "Stopped",
    source      = "ytmusic", -- "ytmusic" | "spotify" | "other"
    player_bus  = nil,
    player_name = "YouTube Music",
    has_spotify = false,
    has_ytmusic = false,
}

mpris.active_bus         = nil
mpris.is_seeking         = false
mpris.ticker_id          = nil
mpris.on_track_change    = nil
mpris.on_status_change   = nil
mpris.on_position_tick   = nil
mpris.on_art_loaded      = nil
mpris.track_listeners    = {}
mpris.position_listeners = {}
mpris.status_listeners   = {}

local last_track_key = ""
local last_art_url   = ""
local bus            = nil

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

function mpris.format_time(sec)
    if not sec or sec < 0 or sec ~= sec then sec = 0 end
    sec = math.floor(sec)
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%02d:%02d", m, s)
end

local function exec_async(argv, callback)
    local ok, sub = pcall(Gio.Subprocess.new, argv,
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE)
    if ok and sub then
        sub:communicate_utf8_async(nil, nil, function(s, res)
            local ok_finish, stdout = pcall(function() return s:communicate_utf8_finish(res) end)
            if callback and ok_finish and stdout and type(stdout) == "string" then
                callback(stdout)
            end
        end)
    end
end

local function load_artwork(art_url)
    if art_url == last_art_url and mpris.track.art_pixbuf ~= nil then
        return
    end
    last_art_url = art_url or ""

    if not art_url or #art_url == 0 then
        mpris.track.art_pixbuf = nil
        if mpris.on_art_loaded then mpris.on_art_loaded(nil) end
        return
    end

    local size = config.PLAYER_COVER_SIZE or 68

    if art_url:find("^file://") then
        local local_path = art_url:gsub("^file://", ""):gsub("%%20", " ")
        local ok, pb = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale, local_path, size, size, true)
        if ok and pb then
            mpris.track.art_pixbuf = pb
            if mpris.on_art_loaded then mpris.on_art_loaded(pb) end
            return
        end
    elseif art_url:find("^https?://") then
        local tmp_file = "/tmp/qwen_widget_album_art.jpg"
        exec_async({"curl", "-sL", "-m", "8", art_url, "-o", tmp_file}, function()
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

function mpris.refresh()
    local pref = config.music_source or "auto"
    if qwen_native and qwen_native.media_get_state then
        local st = qwen_native.media_get_state(pref)
        if st and st.found then
            local title  = (st.title or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local artist = (st.artist or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if #artist == 0 and title:find(" %- ") then
                local a, t = title:match("^(.-) %- (.*)$")
                if a and t then artist = a; title = t end
            end

            local old_status = mpris.track.status
            local key = title .. "|" .. artist .. "|" .. (st.source or "")
            local changed = (key ~= last_track_key and #title > 0)
            last_track_key = key

            mpris.active_bus        = st.bus_name
            mpris.track.player_bus  = st.bus_name
            mpris.track.source      = st.source or "ytmusic"
            mpris.track.player_name = st.player_name or (st.source == "spotify" and "Spotify" or "YouTube Music")
            mpris.track.has_spotify = (st.has_spotify == true)
            mpris.track.has_ytmusic = (st.has_ytmusic == true)
            mpris.track.title       = title
            mpris.track.artist      = artist
            mpris.track.album       = st.album or ""
            mpris.track.art_url     = st.art_url or ""
            mpris.track.length      = tonumber(st.length) or 0
            if not mpris.is_seeking and st.position and st.position > 0 then
                mpris.track.position = tonumber(st.position) or mpris.track.position
            end
            if st.volume and st.volume >= 0 then
                mpris.track.volume = tonumber(st.volume) or 1.0
            end
            mpris.track.status = st.status or "Stopped"

            load_artwork(mpris.track.art_url)

            if changed then
                if mpris.on_track_change then pcall(mpris.on_track_change, mpris.track) end
                for _, fn in ipairs(mpris.track_listeners) do pcall(fn, mpris.track) end
            end

            if old_status ~= mpris.track.status then
                if mpris.on_status_change then pcall(mpris.on_status_change, mpris.track.status) end
                for _, fn in ipairs(mpris.status_listeners) do pcall(fn, mpris.track.status) end
            end
            return
        end
    end
end

function mpris.get_position()
    if mpris.is_seeking then return mpris.track.position end
    if qwen_native and qwen_native.media_get_state then
        local st = qwen_native.media_get_state(config.music_source or "auto")
        if st and st.found and st.position then
            mpris.track.position = tonumber(st.position) or mpris.track.position
            if st.length and st.length > 0 then
                mpris.track.length = tonumber(st.length)
            end
        end
    end
    return mpris.track.position
end

function mpris.set_source(src)
    config.music_source = src or "auto"
    config.save()
    last_track_key = ""
    mpris.refresh()
end

function mpris.play_pause()
    local pref = config.music_source or "auto"
    if qwen_native and qwen_native.media_control then
        qwen_native.media_control("play_pause", 0, pref)
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 120, function()
            mpris.refresh()
            return false
        end)
        return
    end
    exec_async({"playerctl", "play-pause"}, function() mpris.refresh() end)
end

function mpris.next()
    local pref = config.music_source or "auto"
    if qwen_native and qwen_native.media_control then
        qwen_native.media_control("next", 0, pref)
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 220, function()
            mpris.refresh()
            return false
        end)
        return
    end
    exec_async({"playerctl", "next"}, function() mpris.refresh() end)
end

function mpris.previous()
    local pref = config.music_source or "auto"
    if qwen_native and qwen_native.media_control then
        qwen_native.media_control("previous", 0, pref)
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 220, function()
            mpris.refresh()
            return false
        end)
        return
    end
    exec_async({"playerctl", "previous"}, function() mpris.refresh() end)
end

function mpris.seek(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    mpris.track.position = seconds
    mpris.is_seeking = true
    mpris.notify_position(mpris.track.position, mpris.track.length)

    local pref = config.music_source or "auto"
    if qwen_native and qwen_native.media_control then
        qwen_native.media_control("seek", seconds, pref)
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, function()
            mpris.is_seeking = false
            return false
        end)
        return
    end

    exec_async({"playerctl", "position", string.format("%.2f", seconds)}, function()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, function()
            mpris.is_seeking = false
            return false
        end)
    end)
end

function mpris.set_volume(vol)
    vol = math.max(0.0, math.min(1.0, tonumber(vol) or 1.0))
    mpris.track.volume = vol
    local pref = config.music_source or "auto"
    if qwen_native and qwen_native.media_control then
        qwen_native.media_control("volume", vol, pref)
        return
    end
    exec_async({"playerctl", "volume", string.format("%.2f", vol)})
end

function mpris.start()
    local ok_b, b = pcall(Gio.bus_get_sync, Gio.BusType.SESSION)
    if ok_b and b then
        bus = b
        bus:signal_subscribe(
            nil,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            "/org/mpris/MediaPlayer2",
            nil,
            Gio.DBusSignalFlags.NONE,
            function(_, _, _, _, _, params)
                pcall(function()
                    if params and params.value and params.value[1] == "org.mpris.MediaPlayer2.Player" then
                        mpris.refresh()
                    end
                end)
            end)

        bus:signal_subscribe(
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            "/org/freedesktop/DBus",
            nil,
            Gio.DBusSignalFlags.NONE,
            function(_, _, _, _, _, params)
                pcall(function()
                    local name = params.value[1]
                    if name and name:find("^org%.mpris%.MediaPlayer2%.") then
                        mpris.refresh()
                    end
                end)
            end)
    end

    mpris.refresh()

    local tick_interval = config.PLAYER_UPDATE_MS or 250
    local step_sec = tick_interval / 1000
    local sync_counter = 0

    mpris.ticker_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, tick_interval, function()
        if mpris.track.status == "Playing" and not mpris.is_seeking then
            sync_counter = sync_counter + 1
            if sync_counter >= 6 then
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
        return true
    end)
end

return mpris
