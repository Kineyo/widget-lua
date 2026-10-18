----------------------------------------------------------------------
-- lib/skills/app_launch.lua  –  Lanzador de Aplicaciones (Cero Emojis)
----------------------------------------------------------------------
local base = require("skills.base")

local skill = {
    name = "app_launch",
    description = "Lanza aplicaciones de escritorio (navegador, terminal, youtube music, spotify, archivos).",
    params = { app = "nombre de la aplicacion" },
}

function skill.run(args, callback)
    local app = type(args) == "table" and (args.app or args.name) or tostring(args)
    if not app or #app == 0 then
        callback(false, "Aplicacion no especificada")
        return
    end

    local app_map = {
        ["musica"]        = "youtube-music-desktop-app || youtube-music || spotify &",
        ["youtube music"] = "youtube-music-desktop-app || youtube-music || xdg-open 'https://music.youtube.com' &",
        ["spotify"]       = "spotify || flatpak run com.spotify.Client &",
        ["navegador"]     = "xdg-open 'https://www.google.com' &",
        ["terminal"]      = "cosmic-term || gnome-terminal || xterm &",
        ["archivos"]      = "cosmic-files || nautilus &",
        ["calculadora"]   = "gnome-calculator || calc &",
        ["editor"]        = "gedit || code &",
    }

    local cmd = app_map[app:lower()] or (app .. " &")
    base.exec_command(cmd, function()
        callback(true, string.format("[Sistema] Aplicacion iniciada: **%s**", app))
    end, 10, 5)
end

return skill
