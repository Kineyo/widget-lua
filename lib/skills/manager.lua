----------------------------------------------------------------------
-- lib/skills/manager.lua  –  Gestor de Carga Perezosa (Lazy Loading)
--                            Cero emojis. Liberación activa de RAM.
----------------------------------------------------------------------
local config = require("config")

local manager = {}

manager.registry = {
    system_info = {
        name        = "system_info",
        module      = "skills.system_info",
        description = "Obtiene informacion en tiempo real de CPU, memoria RAM, disco, uptime y bateria.",
        config_key  = "system_info",
    },
    bash = {
        name        = "bash",
        module      = "skills.bash",
        description = "Ejecuta comandos de shell en el sistema local con control de timeout.",
        config_key  = "bash",
    },
    media_control = {
        name        = "media_control",
        module      = "skills.media_control",
        description = "Controla YouTube Music y Spotify via MPRIS2 nativo (play, pause, next, prev, seek, volume, status).",
        config_key  = "media_control",
    },
    web_search = {
        name        = "web_search",
        module      = "skills.web_search",
        description = "Busca informacion rapida en la web mediante DuckDuckGo.",
        config_key  = "web_search",
    },
    app_launch = {
        name        = "app_launch",
        module      = "skills.app_launch",
        description = "Lanza aplicaciones de escritorio (navegador, terminal, youtube music, spotify, archivos).",
        config_key  = "app_launch",
    },
    screenshot = {
        name        = "screenshot",
        module      = "skills.screenshot",
        description = "Toma una captura de pantalla del escritorio y la guarda en disco.",
        config_key  = "screenshot",
    },
    notify = {
        name        = "notify",
        module      = "skills.notify",
        description = "Envia una notificacion emergente al escritorio.",
        config_key  = "notify",
    },
    openclaw_gateway = {
        name        = "openclaw_gateway",
        module      = "skills.openclaw_gateway",
        description = "Gestiona la conexion asincrona y estado del Gateway de OpenClaw.",
        config_key  = "openclaw_gateway",
    },
}

manager.loaded = {}

function manager.is_enabled(skill_name)
    local meta = manager.registry[skill_name]
    if not meta then return false end
    local key = meta.config_key or skill_name
    if config.skills and config.skills[key] ~= nil then
        return config.skills[key] == true
    end
    return true
end

function manager.get(skill_name)
    if not manager.is_enabled(skill_name) then
        return nil
    end
    if manager.loaded[skill_name] then
        return manager.loaded[skill_name]
    end
    local meta = manager.registry[skill_name]
    if not meta then return nil end

    local ok, mod = pcall(require, meta.module)
    if ok and mod then
        manager.loaded[skill_name] = mod
        return mod
    end
    return nil
end

function manager.unload(skill_name)
    local mod = manager.loaded[skill_name]
    if mod then
        if type(mod.unload) == "function" then
            pcall(mod.unload)
        end
        manager.loaded[skill_name] = nil
    end
    local meta = manager.registry[skill_name]
    if meta and meta.module then
        package.loaded[meta.module] = nil
    end
    collectgarbage("step", 100)
end

function manager.unload_all()
    for name, _ in pairs(manager.loaded) do
        manager.unload(name)
    end
    collectgarbage("collect")
end

function manager.execute(skill_name, args, callback)
    if not manager.is_enabled(skill_name) then
        if callback then
            callback(false, string.format("[Aviso] La habilidad '%s' esta desactivada en configuracion.", skill_name))
        end
        return
    end

    local sk = manager.get(skill_name)
    if not sk or not sk.run then
        if callback then
            callback(false, "Habilidad no disponible: " .. tostring(skill_name))
        end
        return
    end

    sk.run(args, function(ok, res)
        if callback then callback(ok, res) end
        collectgarbage("step", 100)
    end)
end

function manager.get_active_catalog()
    local list = {}
    for name, meta in pairs(manager.registry) do
        if manager.is_enabled(name) then
            list[name] = {
                name        = meta.name,
                description = meta.description,
            }
        end
    end
    return list
end

config.add_listener(function(key, value)
    if key and manager.registry[key] then
        if value == false then
            manager.unload(key)
        else
            manager.get(key)
        end
    end
end)

return manager
