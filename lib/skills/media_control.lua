----------------------------------------------------------------------
-- lib/skills/media_control.lua  –  Control Multimedia (YT Music + Spotify)
----------------------------------------------------------------------
local lgi   = require("lgi")
local GLib  = lgi.GLib
local mpris = require("mpris")

local skill = {
    name = "media_control",
    description = "Controla YouTube Music y Spotify via MPRIS2 (play, pause, next, prev, seek, volume, status).",
    params = { action = "play|pause|play_pause|next|prev|status|seek|volume", value = "numero opcional" },
}

function skill.run(args, callback)
    local act = "status"
    local val = nil
    if type(args) == "table" then
        act = args.action or args.act or "status"
        val = tonumber(args.value or args.val or args.position)
    elseif type(args) == "string" then
        act = args
    end

    if act == "next" then
        mpris.next()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, function()
            mpris.refresh()
            callback(true, "[Media] Pista siguiente: **" .. (mpris.track.title or "") .. "**")
            return false
        end)
    elseif act == "prev" or act == "previous" then
        mpris.previous()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, function()
            mpris.refresh()
            callback(true, "[Media] Pista anterior: **" .. (mpris.track.title or "") .. "**")
            return false
        end)
    elseif act == "play" or act == "pause" or act == "play_pause" or act == "toggle" then
        mpris.play_pause()
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, function()
            mpris.refresh()
            callback(true, string.format("[Media] Estado: %s (**%s**)", mpris.track.status, mpris.track.title or "N/A"))
            return false
        end)
    elseif act == "seek" and val then
        mpris.seek(val)
        callback(true, string.format("[Media] Posicion ajustada a %s", mpris.format_time(val)))
    elseif act == "volume" and val then
        local v = val > 1 and (val / 100.0) or val
        mpris.set_volume(v)
        callback(true, string.format("[Media] Volumen ajustado a %d%%", math.floor(v * 100)))
    else
        mpris.refresh()
        local t = mpris.track
        if #t.title > 0 then
            local res = string.format(
                "**[Reproductor: %s]**\n- **Titulo:** %s\n- **Artista:** %s\n- **Estado:** %s\n- **Tiempo:** %s / %s",
                t.player_name or "MPRIS2",
                t.title,
                #t.artist > 0 and t.artist or "Desconocido",
                t.status,
                mpris.format_time(t.position),
                mpris.format_time(t.length)
            )
            callback(true, res)
        else
            callback(true, "[Media] No hay reproduccion activa en YouTube Music ni Spotify.")
        end
    end
end

return skill
