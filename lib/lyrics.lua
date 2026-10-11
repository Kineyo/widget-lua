----------------------------------------------------------------------
-- lyrics.lua  –  Synchronized LRC Lyrics Manager for YouTube Music
--                Cleans titles, fetches from LRCLIB, parses timestamps,
--                and synchronizes with MPRIS playback in real time.
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gio    = lgi.Gio
local GLib   = lgi.GLib

local json   = require("json")
local config = require("config")

local lyrics = {}

-- State
lyrics.active_lines      = nil  -- sorted array of { time = sec, text = string }
lyrics.current_track_key = ""
lyrics.current_line_text = nil
lyrics.cache             = {}   -- [key] = lines_table or false
lyrics.is_fetching       = false
lyrics.last_fetch_id     = 0

-- Callbacks
lyrics.on_line_change    = nil  -- function(text)
lyrics.on_hide           = nil  -- function()

----------------------------------------------------------------------
-- Helper: Asynchronous command execution via Gio.Subprocess
----------------------------------------------------------------------
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

----------------------------------------------------------------------
-- Clean artist and song title from YouTube Music / browser tags
----------------------------------------------------------------------
function lyrics.clean_song_info(raw_title, raw_artist)
    local title = raw_title or ""
    local artist = raw_artist or ""

    -- Strip leading/trailing whitespace
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    artist = artist:gsub("^%s+", ""):gsub("%s+$", "")

    -- If artist is generic browser name or missing, check if title contains "Artist - Title"
    local lower_a = artist:lower()
    if #artist == 0 or lower_a == "youtube music" or lower_a:find("chromium") or lower_a:find("chrome") or lower_a:find("firefox") then
        if title:find(" %- ") then
            local a, t = title:match("^(.-) %- (.*)$")
            if a and t then
                artist = a
                title = t
            end
        end
    end

    -- Remove common video suffixes in parenthesis/brackets
    title = title:gsub("%s*%b()", function(inside)
        local lower = inside:lower()
        if lower:find("official") or lower:find("video") or lower:find("audio")
           or lower:find("lyric") or lower:find("lyrics") or lower:find("mv")
           or lower:find("visualizer") or lower:find("remaster") or lower:find("hd")
           or lower:find("4k") or lower:find("feat") or lower:find("ft%.") then
            return ""
        end
        return inside
    end)

    title = title:gsub("%s*%b[]", function(inside)
        local lower = inside:lower()
        if lower:find("official") or lower:find("video") or lower:find("audio")
           or lower:find("lyric") or lower:find("lyrics") or lower:find("mv")
           or lower:find("visualizer") or lower:find("remaster") or lower:find("hd")
           or lower:find("4k") or lower:find("feat") or lower:find("ft%.") then
            return ""
        end
        return inside
    end)

    -- Clean Topic / YouTube Music suffixes
    title = title:gsub("%s*%-%s*Topic$", "")
    title = title:gsub("%s*%-%s*YouTube Music$", "")
    title = title:gsub("%s*%-%s*YouTube$", "")
    artist = artist:gsub("%s*%-%s*Topic$", "")
    artist = artist:gsub("%s*%-%s*YouTube Music$", "")

    -- Clean remaining punctuation
    title = title:gsub("^[-%|%s]+", ""):gsub("[-%|%s]+$", "")
    artist = artist:gsub("^[-%|%s]+", ""):gsub("[-%|%s]+$", "")

    return title, artist
end

----------------------------------------------------------------------
-- Parse LRC formatted synchronized text
----------------------------------------------------------------------
function lyrics.parse_lrc(lrc_text)
    if not lrc_text or #lrc_text == 0 then return nil end

    local lines = {}
    for line in lrc_text:gmatch("[^\r\n]+") do
        -- Skip ID tags like [ar: ...], [ti: ...], [al: ...]
        if not line:match("^%[%a+:") then
            -- Strip inline word-sync timestamps like <00:12.34>
            local clean_line = line:gsub("<%d+:%d+%.?%d*>", "")

            -- Extract all timestamp prefixes [mm:ss.xx]
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

    -- Sort lines by timestamp
    table.sort(lines, function(a, b) return a.time < b.time end)
    return lines
end

----------------------------------------------------------------------
-- Fetch synchronized lyrics from LRCLIB asynchronously
----------------------------------------------------------------------
function lyrics.fetch_async(title, artist, duration, callback)
    local clean_t, clean_a = lyrics.clean_song_info(title, artist)
    if #clean_t == 0 then
        if callback then callback(nil) end
        return
    end

    local cache_key = clean_a .. "::" .. clean_t
    if lyrics.cache[cache_key] ~= nil then
        if callback then callback(lyrics.cache[cache_key] or nil) end
        return
    end

    lyrics.last_fetch_id = lyrics.last_fetch_id + 1
    local this_fetch_id = lyrics.last_fetch_id

    -- Step 1: Direct match via /api/get
    local argv_get = {
        "curl", "-s", "-m", "5", "--compressed", "-G",
        "--data-urlencode", "artist_name=" .. clean_a,
        "--data-urlencode", "track_name=" .. clean_t,
        "-H", "User-Agent: QwenWidget/2.0 (PopOS Linux Desktop; OpenClaw)",
        "https://lrclib.net/api/get"
    }
    if duration and duration > 0 then
        table.insert(argv_get, 7, "--data-urlencode")
        table.insert(argv_get, 8, "duration=" .. tostring(math.floor(duration)))
    end

    exec_async(argv_get, function(body)
        if this_fetch_id ~= lyrics.last_fetch_id then return end

        if body then
            local data = json.decode(body)
            if data and type(data) == "table" then
                -- If instrumental or explicitly no synced lyrics
                if data.instrumental == true then
                    lyrics.cache[cache_key] = false
                    if callback then callback(nil) end
                    return
                end

                if data.syncedLyrics and #data.syncedLyrics > 0 then
                    local lines = lyrics.parse_lrc(data.syncedLyrics)
                    if lines and #lines > 0 then
                        lyrics.cache[cache_key] = lines
                        if callback then callback(lines) end
                        return
                    end
                end
            end
        end

        -- Step 2: Fallback search via /api/search
        local q = clean_a .. " " .. clean_t
        local argv_search = {
            "curl", "-s", "-m", "5", "--compressed", "-G",
            "--data-urlencode", "q=" .. q,
            "-H", "User-Agent: QwenWidget/2.0 (PopOS Linux Desktop; OpenClaw)",
            "https://lrclib.net/api/search"
        }

        exec_async(argv_search, function(search_body)
            if this_fetch_id ~= lyrics.last_fetch_id then return end

            if search_body then
                local sdata = json.decode(search_body)
                if sdata and type(sdata) == "table" and #sdata > 0 then
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
                        local lines = lyrics.parse_lrc(best_item.syncedLyrics)
                        if lines and #lines > 0 then
                            lyrics.cache[cache_key] = lines
                            if callback then callback(lines) end
                            return
                        end
                    end
                end
            end

            -- Step 3: Fallback search by title only (for covers/channels like "Suriw")
            if #clean_a > 0 then
                local argv_title = {
                    "curl", "-s", "-m", "5", "--compressed", "-G",
                    "--data-urlencode", "q=" .. clean_t,
                    "-H", "User-Agent: QwenWidget/2.0 (PopOS Linux Desktop; OpenClaw)",
                    "https://lrclib.net/api/search"
                }

                exec_async(argv_title, function(title_body)
                    if this_fetch_id ~= lyrics.last_fetch_id then return end

                    if title_body then
                        local tdata = json.decode(title_body)
                        if tdata and type(tdata) == "table" and #tdata > 0 then
                            for _, item in ipairs(tdata) do
                                if item.syncedLyrics and #item.syncedLyrics > 0 then
                                    local lines = lyrics.parse_lrc(item.syncedLyrics)
                                    if lines and #lines > 0 then
                                        lyrics.cache[cache_key] = lines
                                        if callback then callback(lines) end
                                        return
                                    end
                                end
                            end
                        end
                    end

                    -- No lyrics found or instrumental: cache as false so we don't spam network
                    lyrics.cache[cache_key] = false
                    if callback then callback(nil) end
                end)
                return
            end

            -- No lyrics found or instrumental: cache as false so we don't spam network
            lyrics.cache[cache_key] = false
            if callback then callback(nil) end
        end)
    end)
end

----------------------------------------------------------------------
-- Find the active lyrics line corresponding to playback position
----------------------------------------------------------------------
local function get_active_line(lines, pos)
    if not lines or #lines == 0 then return nil end

    local active = nil
    local next_time = nil

    for i = 1, #lines do
        if lines[i].time <= pos then
            active = lines[i]
            if lines[i+1] then
                next_time = lines[i+1].time
            else
                next_time = nil
            end
        else
            break
        end
    end

    if not active then
        -- Before the first lyric line (intro)
        return nil
    end

    -- If line text is empty, it marks an instrumental section in LRC
    if not active.text or #active.text == 0 then
        return nil
    end

    -- If next line is far in the future (e.g. > 8s) and the line has been showing
    -- for > 7.5 seconds, hide the bubble during the musical break/interlude
    local elapsed = pos - active.time
    local max_stay = 7.5
    if next_time then
        local gap = next_time - active.time
        if gap > max_stay and elapsed > max_stay then
            return nil
        end
    else
        -- Last line of song
        if elapsed > max_stay then
            return nil
        end
    end

    return active
end

----------------------------------------------------------------------
-- Handle position tick from MPRIS
----------------------------------------------------------------------
function lyrics.on_position(pos, length)
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

    -- If line changed, notify UI to dynamically update speech bubble
    if line.text ~= lyrics.current_line_text then
        lyrics.current_line_text = line.text
        if lyrics.on_line_change then
            lyrics.on_line_change(line.text)
        end
    end
end

----------------------------------------------------------------------
-- Set or change current playing track
----------------------------------------------------------------------
function lyrics.set_track(track)
    if not track or not track.title or #track.title == 0 or track.status == "Stopped" then
        lyrics.reset()
        return
    end

    local clean_t, clean_a = lyrics.clean_song_info(track.title, track.artist)
    local key = clean_a .. "::" .. clean_t

    if key == lyrics.current_track_key and lyrics.active_lines ~= nil then
        -- Same track, just sync position
        lyrics.on_position(track.position or 0, track.length or 0)
        return
    end

    lyrics.current_track_key = key
    lyrics.active_lines = nil
    lyrics.current_line_text = nil
    if lyrics.on_hide then lyrics.on_hide() end

    -- Check cache
    if lyrics.cache[key] ~= nil then
        local cached = lyrics.cache[key]
        if cached and type(cached) == "table" and #cached > 0 then
            lyrics.active_lines = cached
            lyrics.on_position(track.position or 0, track.length or 0)
        else
            -- Cached as false (no lyrics)
            lyrics.active_lines = nil
        end
        return
    end

    -- Fetch from LRCLIB
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

----------------------------------------------------------------------
-- Status change
----------------------------------------------------------------------
function lyrics.set_status(status)
    if status == "Stopped" then
        lyrics.reset()
    end
end

----------------------------------------------------------------------
-- Reset / hide lyrics
----------------------------------------------------------------------
function lyrics.reset()
    lyrics.current_track_key = ""
    lyrics.active_lines = nil
    lyrics.current_line_text = nil
    lyrics.last_fetch_id = lyrics.last_fetch_id + 1
    if lyrics.on_hide then lyrics.on_hide() end
end

return lyrics
