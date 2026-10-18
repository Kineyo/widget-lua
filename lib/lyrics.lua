----------------------------------------------------------------------
-- lyrics.lua  –  Synchronized LRC Lyrics Manager (YouTube Music + Spotify)
--                Supports timestamp offset adjustment, local disk cache,
--                and LRCLIB API fallback.
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gio    = lgi.Gio
local GLib   = lgi.GLib

local json   = require("json")
local config = require("config")

local lyrics = {}

lyrics.active_lines      = nil
lyrics.current_track_key = ""
lyrics.current_line_text = nil
lyrics.cache             = {}
lyrics.is_fetching       = false
lyrics.last_fetch_id     = 0

lyrics.on_line_change    = nil
lyrics.on_hide           = nil

local CACHE_DIR = (os.getenv("HOME") or ".") .. "/.cache/qwen-widget/lyrics"

local function ensure_cache_dir()
    GLib.mkdir_with_parents(CACHE_DIR, 493) -- 0755
end

local function disk_cache_path(key)
    ensure_cache_dir()
    local safe = key:gsub("[^%w%-_]", "_"):sub(1, 100)
    return CACHE_DIR .. "/" .. safe .. ".lrc"
end

local function exec_async(argv, callback)
    local ok, sub = pcall(Gio.Subprocess.new, argv,
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE)
    if not ok or not sub then
        if callback then callback(nil) end
        return
    end

    sub:communicate_utf8_async(nil, nil, function(subprocess, result)
        local ok_fin, stdout = pcall(function() return subprocess:communicate_utf8_finish(result) end)
        if ok_fin and stdout and #stdout > 0 and callback then
            callback(stdout)
        elseif callback then
            callback(nil)
        end
    end)
end

-- Clean artist and song title from YouTube Music, Spotify, and browser tags
function lyrics.clean_song_info(raw_title, raw_artist)
    local title = raw_title or ""
    local artist = raw_artist or ""

    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    artist = artist:gsub("^%s+", ""):gsub("%s+$", "")

    local lower_a = artist:lower()
    if #artist == 0 or lower_a == "youtube music" or lower_a == "spotify"
       or lower_a:find("chromium") or lower_a:find("chrome") or lower_a:find("firefox") then
        if title:find(" %- ") then
            local a, t = title:match("^(.-) %- (.*)$")
            if a and t then
                artist = a
                title = t
            end
        end
    end

    -- If multiple artists separated by comma, keep primary artist for cleaner LRC lookup
    if artist:find(",") then
        artist = artist:match("^([^,]+)") or artist
    end

    local function strip_tag(inside)
        local lower = inside:lower()
        if lower:find("official") or lower:find("video") or lower:find("audio")
           or lower:find("lyric") or lower:find("lyrics") or lower:find("mv")
           or lower:find("visualizer") or lower:find("remaster") or lower:find("hd")
           or lower:find("4k") or lower:find("feat") or lower:find("ft%.")
           or lower:find("nightcore") or lower:find("version") or lower:find("edit") then
            return ""
        end
        return inside
    end

    title = title:gsub("%s*%b()", strip_tag)
    title = title:gsub("%s*%b[]", strip_tag)

    -- Strip Spotify "- Remastered 20xx" suffix
    title = title:gsub("%s*%-%s*[Rr]emaster(ed)?.*$", "")
    title = title:gsub("%s*%-%s*Topic$", "")
    title = title:gsub("%s*%-%s*YouTube Music$", "")
    title = title:gsub("%s*%-%s*Spotify$", "")
    artist = artist:gsub("%s*%-%s*Topic$", "")

    title = title:gsub("^[-%|%s]+", ""):gsub("[-%|%s]+$", "")
    artist = artist:gsub("^[-%|%s]+", ""):gsub("[-%|%s]+$", "")

    return title, artist
end

function lyrics.parse_lrc(lrc_text)
    if not lrc_text or #lrc_text == 0 then return nil end

    local lines = {}
    for line in lrc_text:gmatch("[^\r\n]+") do
        if not line:match("^%[%a+:") then
            local clean_line = line:gsub("<%d+:%d+%.?%d*>", "")
            local timestamps = {}
            local pos = 1
            while true do
                local m_start, m_end, min_str, sec_str = clean_line:find("^%[(%d+):(%d+%.?%d*)%]", pos)
                if not m_start then break end
                local total = (tonumber(min_str) or 0) * 60 + (tonumber(sec_str) or 0)
                table.insert(timestamps, total)
                pos = m_end + 1
            end

            local text = clean_line:sub(pos):gsub("^%s+", ""):gsub("%s+$", "")
            for _, ts in ipairs(timestamps) do
                table.insert(lines, { time = ts, text = text })
            end
        end
    end

    if #lines == 0 then return nil end
    table.sort(lines, function(a, b) return a.time < b.time end)
    return lines
end

function lyrics.fetch_async(title, artist, duration, callback)
    local clean_t, clean_a = lyrics.clean_song_info(title, artist)
    if #clean_t == 0 then
        if callback then callback(nil) end
        return
    end

    local cache_key = (clean_a .. "::" .. clean_t):lower()
    if lyrics.cache[cache_key] ~= nil then
        if callback then callback(lyrics.cache[cache_key] or nil) end
        return
    end

    -- Check local disk cache first
    local dpath = disk_cache_path(cache_key)
    local df = io.open(dpath, "r")
    if df then
        local raw_lrc = df:read("*a")
        df:close()
        local parsed = lyrics.parse_lrc(raw_lrc)
        if parsed and #parsed > 0 then
            lyrics.cache[cache_key] = parsed
            if callback then callback(parsed) end
            return
        end
    end

    lyrics.last_fetch_id = lyrics.last_fetch_id + 1
    local this_fetch_id = lyrics.last_fetch_id

    local function save_and_return(raw_lrc)
        local lines = lyrics.parse_lrc(raw_lrc)
        if lines and #lines > 0 then
            lyrics.cache[cache_key] = lines
            local wf = io.open(dpath, "w")
            if wf then
                wf:write(raw_lrc)
                wf:close()
            end
            if callback then callback(lines) end
            return true
        end
        return false
    end

    local argv_get = {
        "curl", "-s", "-m", "5", "--compressed", "-G",
        "--data-urlencode", "artist_name=" .. clean_a,
        "--data-urlencode", "track_name=" .. clean_t,
        "-H", "User-Agent: QwenWidget/2.0 (PopOS; Hybrid C++/Lua)",
        "https://lrclib.net/api/get"
    }
    if duration and duration > 0 then
        table.insert(argv_get, 7, "--data-urlencode")
        table.insert(argv_get, 8, "duration=" .. tostring(math.floor(duration)))
    end

    exec_async(argv_get, function(body)
        if this_fetch_id ~= lyrics.last_fetch_id then return end

        if body then
            local ok_d, data = pcall(json.decode, body)
            if ok_d and data and type(data) == "table" then
                if data.instrumental == true then
                    lyrics.cache[cache_key] = false
                    if callback then callback(nil) end
                    return
                end
                if data.syncedLyrics and #data.syncedLyrics > 0 then
                    if save_and_return(data.syncedLyrics) then return end
                end
            end
        end

        local q = (#clean_a > 0) and (clean_a .. " " .. clean_t) or clean_t
        local argv_search = {
            "curl", "-s", "-m", "5", "--compressed", "-G",
            "--data-urlencode", "q=" .. q,
            "-H", "User-Agent: QwenWidget/2.0 (PopOS; Hybrid C++/Lua)",
            "https://lrclib.net/api/search"
        }

        exec_async(argv_search, function(search_body)
            if this_fetch_id ~= lyrics.last_fetch_id then return end

            if search_body then
                local ok_s, sdata = pcall(json.decode, search_body)
                if ok_s and sdata and type(sdata) == "table" and #sdata > 0 then
                    local best_item = nil
                    local min_diff = 999999
                    for _, item in ipairs(sdata) do
                        if item.syncedLyrics and #item.syncedLyrics > 0 then
                            if duration and duration > 0 and item.duration and item.duration > 0 then
                                local diff = math.abs(item.duration - duration)
                                if diff < min_diff then
                                    min_diff = diff
                                    best_item = item
                                end
                            else
                                best_item = item
                                break
                            end
                        end
                    end
                    if best_item and best_item.syncedLyrics then
                        if save_and_return(best_item.syncedLyrics) then return end
                    end
                end
            end

            if #clean_a > 0 then
                local argv_title = {
                    "curl", "-s", "-m", "5", "--compressed", "-G",
                    "--data-urlencode", "q=" .. clean_t,
                    "-H", "User-Agent: QwenWidget/2.0 (PopOS; Hybrid C++/Lua)",
                    "https://lrclib.net/api/search"
                }
                exec_async(argv_title, function(title_body)
                    if this_fetch_id ~= lyrics.last_fetch_id then return end
                    if title_body then
                        local ok_t, tdata = pcall(json.decode, title_body)
                        if ok_t and tdata and type(tdata) == "table" and #tdata > 0 then
                            for _, item in ipairs(tdata) do
                                if item.syncedLyrics and #item.syncedLyrics > 0 then
                                    if save_and_return(item.syncedLyrics) then return end
                                end
                            end
                        end
                    end
                    lyrics.cache[cache_key] = false
                    if callback then callback(nil) end
                end)
                return
            end

            lyrics.cache[cache_key] = false
            if callback then callback(nil) end
        end)
    end)
end

local function get_active_line(lines, pos)
    if not lines or #lines == 0 then return nil end

    -- Apply user-configured lyrics offset (in milliseconds)
    local offset_sec = (tonumber(config.lyrics_offset_ms) or 0) / 1000.0
    local effective_pos = math.max(0, pos - offset_sec)

    local active = nil
    local next_time = nil

    for i = 1, #lines do
        if lines[i].time <= effective_pos then
            active = lines[i]
            next_time = lines[i + 1] and lines[i + 1].time or nil
        else
            break
        end
    end

    if not active or not active.text or #active.text == 0 then
        return nil
    end

    local elapsed = effective_pos - active.time
    local max_stay = 8.0
    if next_time then
        local gap = next_time - active.time
        if gap > max_stay and elapsed > max_stay then
            return nil
        end
    elseif elapsed > max_stay then
        return nil
    end

    return active
end

function lyrics.on_position(pos, length)
    if not config.LYRICS_ENABLED then
        if lyrics.current_line_text ~= nil then
            lyrics.current_line_text = nil
            if lyrics.on_hide then lyrics.on_hide() end
        end
        return
    end

    if not lyrics.active_lines or #lyrics.active_lines == 0 then
        if lyrics.current_line_text ~= nil then
            lyrics.current_line_text = nil
            if lyrics.on_hide then lyrics.on_hide() end
        end
        return
    end

    local line = get_active_line(lyrics.active_lines, pos)
    if not line or not line.text or #line.text == 0 then
        if lyrics.current_line_text ~= nil then
            lyrics.current_line_text = nil
            if lyrics.on_hide then lyrics.on_hide() end
        end
        return
    end

    if line.text ~= lyrics.current_line_text then
        lyrics.current_line_text = line.text
        if lyrics.on_line_change then
            lyrics.on_line_change(line.text)
        end
    end
end

function lyrics.set_track(track)
    if not track or not track.title or #track.title == 0 or track.status == "Stopped" then
        lyrics.reset()
        return
    end

    local clean_t, clean_a = lyrics.clean_song_info(track.title, track.artist)
    local key = (clean_a .. "::" .. clean_t):lower()

    if key == lyrics.current_track_key and lyrics.active_lines ~= nil then
        lyrics.on_position(track.position or 0, track.length or 0)
        return
    end

    lyrics.current_track_key = key
    lyrics.active_lines = nil
    lyrics.current_line_text = nil
    if lyrics.on_hide then lyrics.on_hide() end

    lyrics.fetch_async(track.title, track.artist, track.length, function(lines)
        if lyrics.current_track_key ~= key then return end
        if lines and #lines > 0 then
            lyrics.active_lines = lines
            lyrics.on_position(track.position or 0, track.length or 0)
        else
            lyrics.active_lines = nil
            if lyrics.on_hide then lyrics.on_hide() end
        end
    end)
end

function lyrics.set_status(status)
    if status == "Stopped" then
        lyrics.reset()
    end
end

function lyrics.adjust_offset(delta_ms)
    config.lyrics_offset_ms = (tonumber(config.lyrics_offset_ms) or 0) + delta_ms
    config.save()
end

function lyrics.reset()
    lyrics.current_track_key = ""
    lyrics.active_lines = nil
    lyrics.current_line_text = nil
    lyrics.last_fetch_id = lyrics.last_fetch_id + 1
    if lyrics.on_hide then lyrics.on_hide() end
end

return lyrics
