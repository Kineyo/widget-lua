----------------------------------------------------------------------
-- openclaw_agent.lua  –  OpenClaw Agent & Skills Orchestrator
--                        100% Async IPC/HTTP, safe JSON payload parsing,
--                        automatic retries, and zero emojis.
----------------------------------------------------------------------
local config    = require("config")
local json      = require("json")
local manager   = require("skills.manager")
local base      = require("skills.base")

local agent = {}

agent.enabled       = true
agent.gateway_alive = false

agent.skills = setmetatable({}, {
    __index = function(_, k)
        return manager.get(k)
    end,
    __pairs = function(_)
        local cat = manager.get_active_catalog()
        return pairs(cat)
    end,
})

function agent.execute(skill_name, args, callback)
    manager.execute(skill_name, args, function(ok, res)
        if callback then callback(ok, res) end
        collectgarbage("step", 50)
    end)
end

-- Check or reconnect to OpenClaw Gateway asynchronously without blocking UI
function agent.check_gateway(callback)
    local gw_url = config.OPENCLAW_GATEWAY_URL or "http://127.0.0.1:18789"
    local timeout = tonumber(config.OPENCLAW_TIMEOUT_SEC) or 4
    base.http_json_request(gw_url .. "/health", "GET", nil, timeout, 1, function(ok, data)
        agent.gateway_alive = (ok == true)
        if callback then callback(agent.gateway_alive, data) end
    end)
end

function agent.handle_slash_command(text, callback)
    if not text or not text:find("^/") then return false end

    local cmd, arg_str = text:match("^/(%S+)%s*(.*)$")
    if not cmd then return false end
    cmd = cmd:lower()

    if cmd == "help" or cmd == "ayuda" then
        local help_text = table.concat({
            "**[OpenClaw Agent - Comandos Disponibles]**",
            "- `/sys` o `/status` - Diagnostico de CPU, RAM del sistema, RAM del widget y almacenamiento",
            "- `/music` o `/player` - Estado actual de YouTube Music y Spotify",
            "- `/next`, `/prev`, `/play`, `/pause` - Controles directos de reproduccion",
            "- `/sh <comando>` - Ejecuta un comando en terminal con control de timeout",
            "- `/search <consulta>` - Busqueda rapida en la web",
            "- `/app <nombre>` - Inicia una aplicacion (spotify, youtube music, terminal, navegador)",
            "- `/shot` o `/screenshot` - Toma una captura de pantalla",
            "- `/skills` - Lista el catalogo de habilidades activas",
            "- `/gateway [mensaje]` - Verifica o envia un payload al Gateway de OpenClaw",
            "- `/model <nombre>` - Cambia el modelo local GGUF o Cloud",
            "- `/clear` - Reinicia el historial de conversacion y libera memoria",
        }, "\n")
        callback(help_text)
        return true

    elseif cmd == "skills" or cmd == "habilidades" then
        local list = { "**[Catalogo de Habilidades OpenClaw Activas]**" }
        local cat = manager.get_active_catalog()
        for name, meta in pairs(cat) do
            list[#list + 1] = string.format("- **%s**: %s", name, meta.description)
        end
        callback(table.concat(list, "\n"))
        return true

    elseif cmd == "sys" or cmd == "status" then
        agent.execute("system_info", {}, function(_, res)
            callback(res)
        end)
        return true

    elseif cmd == "music" or cmd == "player" or cmd == "reproductor" then
        agent.execute("media_control", { action = "status" }, function(_, res)
            callback(res)
        end)
        return true

    elseif cmd == "bubble" or cmd == "burbuja" or cmd == "info" then
        local ok_f, fetchers = pcall(require, "fetchers")
        local fact = ok_f and fetchers.get_random_fact() or "[Sistema] Informacion activa"
        callback(fact)
        return true

    elseif cmd == "next" or cmd == "siguiente" then
        agent.execute("media_control", { action = "next" }, function(_, res)
            callback(res)
        end)
        return true

    elseif cmd == "prev" or cmd == "anterior" then
        agent.execute("media_control", { action = "prev" }, function(_, res)
            callback(res)
        end)
        return true

    elseif cmd == "play" or cmd == "pause" or cmd == "toggle" then
        agent.execute("media_control", { action = "play_pause" }, function(_, res)
            callback(res)
        end)
        return true

    elseif cmd == "sh" or cmd == "bash" or cmd == "exec" then
        if #arg_str == 0 then
            callback("[Aviso] Uso: `/sh <comando bash>` (ejemplo: `/sh free -h`)")
        else
            agent.execute("bash", { command = arg_str }, function(_, res)
                callback(res)
            end)
        end
        return true

    elseif cmd == "search" or cmd == "buscar" then
        if #arg_str == 0 then
            callback("[Aviso] Uso: `/search <termino>`")
        else
            agent.execute("web_search", { query = arg_str }, function(_, res)
                callback(res)
            end)
        end
        return true

    elseif cmd == "app" or cmd == "abrir" then
        if #arg_str == 0 then
            callback("[Aviso] Uso: `/app <nombre>` (ejemplo: `/app spotify` o `/app youtube music`)")
        else
            agent.execute("app_launch", { app = arg_str }, function(_, res)
                callback(res)
            end)
        end
        return true

    elseif cmd == "shot" or cmd == "screenshot" or cmd == "captura" then
        agent.execute("screenshot", {}, function(_, res)
            callback(res)
        end)
        return true

    elseif cmd == "gateway" or cmd == "openclaw" then
        local gw_args = (#arg_str > 0) and { action = "send", payload = arg_str } or { action = "status" }
        agent.execute("openclaw_gateway", gw_args, function(_, res)
            callback(res)
        end)
        return true

    elseif cmd == "model" or cmd == "modelo" then
        if #arg_str > 0 then
            config.chat_model  = arg_str
            config.llama_model = arg_str
            config.save()
            config.notify_change("chat_model", arg_str)
            callback("[Configuracion] Modelo conversacional actualizado a: **" .. config.chat_model .. "**")
        else
            callback(string.format(
                "**[Modelos Configurados]**\n- Chat Local: `%s`\n- Gramatica Local: `%s`\n- Proveedor Activo: `%s`",
                config.chat_model or "qwen3.0-0.8b.gguf",
                config.grammar_model or "es-grammar.gguf",
                config.inference_provider or "local"
            ))
        end
        return true
    end

    return false
end

function agent.detect_tool_call(text)
    if not text then return nil end

    local tool_name, json_body = text:match("```tool:(%w+)%s*(%b{})%s*```")
    if not tool_name then
        tool_name, json_body = text:match("```tool%s*(%b{})%s*```")
    end

    if json_body then
        local ok_d, d = pcall(json.decode, json_body)
        if ok_d and type(d) == "table" then
            local name = tool_name or d.tool or d.name
            local args = d.args or d.params or d
            return name, args
        end
    end

    local raw_json = text:match("(%{%s*\"tool\"%s*:%s*\"[^\"]+\"%s*,.-%})")
    if raw_json then
        local ok_d, d = pcall(json.decode, raw_json)
        if ok_d and type(d) == "table" and d.tool then
            return d.tool, d.args or d
        end
    end

    return nil
end

function agent.get_system_prompt()
    local cat = manager.get_active_catalog()
    local tool_lines = {}
    local i = 1
    for name, meta in pairs(cat) do
        tool_lines[#tool_lines + 1] = string.format("%d. %s: %s", i, name, meta.description)
        i = i + 1
    end

    local tools_str = table.concat(tool_lines, "\n")
    return string.format([[Eres OpenClaw-Qwen, un asistente de escritorio local ultraligero impulsado por llama.cpp.
Habilidades activas del sistema:
%s

Si el usuario solicita explícitamente ejecutar una acción del sistema, usa el bloque:
```tool:nombre_habilidad
{"parametro": "valor"}
```
Si el usuario conversa o hace una pregunta general, responde directamente en español con claridad, sin usar emojis y sin invocar herramientas innecesarias.]], tools_str)
end

return agent
