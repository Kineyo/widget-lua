----------------------------------------------------------------------
-- lib/skills/notify.lua  –  Notificaciones de Escritorio (Cero Emojis)
----------------------------------------------------------------------
local base = require("skills.base")

local skill = {
    name = "notify",
    description = "Envia una notificacion emergente al escritorio.",
    params = { title = "titulo", message = "mensaje" },
}

function skill.run(args, callback)
    local title = "Qwen Desktop Widget"
    local msg = "Aviso del asistente"
    if type(args) == "table" then
        title = args.title or title
        msg = args.message or args.msg or msg
    elseif type(args) == "string" then
        msg = args
    end

    base.exec_command(string.format("notify-send '%s' '%s' -i dialog-information", title:gsub("'", ""), msg:gsub("'", "")), function()
        callback(true, string.format("[Notificacion] Enviada: **%s**", title))
    end, 5, 5)
end

return skill
