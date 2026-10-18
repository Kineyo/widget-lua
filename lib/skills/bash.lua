----------------------------------------------------------------------
-- lib/skills/bash.lua  –  Habilidad de Ejecucion en Shell (Cero Emojis)
----------------------------------------------------------------------
local base = require("skills.base")

local skill = {
    name = "bash",
    description = "Ejecuta comandos de shell en el sistema local y retorna la salida.",
    params = { command = "string (comando a ejecutar)" },
}

function skill.run(args, callback)
    local cmd = type(args) == "table" and (args.command or args.cmd) or tostring(args)
    if not cmd or #cmd == 0 then
        callback(false, "Comando vacio")
        return
    end

    base.exec_command(cmd, function(ok, out)
        local res = string.format("**[Shell `%s`]:**\n```bash\n%s\n```", cmd, #out > 0 and out or "(Completado sin salida)")
        callback(ok, res)
        collectgarbage("step", 50)
    end, 40, 15)
end

return skill
