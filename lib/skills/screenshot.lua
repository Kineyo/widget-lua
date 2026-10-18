----------------------------------------------------------------------
-- lib/skills/screenshot.lua  –  Captura de Pantalla (Cero Emojis)
----------------------------------------------------------------------
local base = require("skills.base")

local skill = {
    name = "screenshot",
    description = "Toma una captura de pantalla del escritorio y la guarda en disco.",
    params = {},
}

function skill.run(args, callback)
    local path = (os.getenv("HOME") or "/home/alex") .. "/Imágenes/Capturas/captura_" .. os.date("%Y%m%d_%H%M%S") .. ".png"
    local cmd = string.format("mkdir -p $(dirname '%s') && (grim '%s' 2>/dev/null || maim '%s' 2>/dev/null || gnome-screenshot -f '%s' 2>/dev/null || import -window root '%s' 2>/dev/null)",
        path, path, path, path, path)
    base.exec_command(cmd, function(ok)
        if ok then
            callback(true, string.format("[Captura] Guardada en:\n`%s`", path))
        else
            callback(false, "[Aviso] No se pudo tomar la captura (instala grim, maim o gnome-screenshot).")
        end
    end, 5, 8)
end

return skill
