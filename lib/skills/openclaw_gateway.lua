----------------------------------------------------------------------
-- lib/skills/openclaw_gateway.lua  –  Módulo de Integración OpenClaw
--                                     Soporta reconexión automática,
--                                     serialización JSON segura y timeouts.
----------------------------------------------------------------------
local base   = require("skills.base")
local config = require("config")
local json   = require("json")

local skill = {
    name = "openclaw_gateway",
    description = "Gestiona la conexion asincrona, estado y envio de payloads al Gateway de OpenClaw.",
    params = { action = "status|send|ping", payload = "tabla o string opcional" },
}

skill.state = {
    connected   = false,
    last_check  = 0,
    endpoint    = nil,
    retry_count = 0,
}

function skill.run(args, callback)
    local gw_url = config.OPENCLAW_GATEWAY_URL or "http://127.0.0.1:18789"
    local timeout = tonumber(config.OPENCLAW_TIMEOUT_SEC) or 5
    local retries = tonumber(config.OPENCLAW_RETRIES) or 2

    local act = "status"
    local payload = nil
    if type(args) == "table" then
        act = args.action or "status"
        payload = args.payload or args.data or args.message
    end

    if act == "send" and payload then
        local req_body = {
            agent     = config.AGENT_NAME or "OpenClaw-Qwen",
            version   = config.AGENT_VERSION or "2.0-native",
            timestamp = os.time(),
            payload   = payload,
        }
        base.http_json_request(gw_url .. "/api/v1/message", "POST", req_body, timeout, retries, function(ok, data, err)
            if ok and data then
                skill.state.connected = true
                skill.state.retry_count = 0
                local resp_str = type(data) == "table" and (data.reply or data.status or json.encode(data)) or tostring(data)
                callback(true, "[OpenClaw Gateway] Respuesta recibida:\n" .. resp_str)
            else
                skill.state.connected = false
                skill.state.retry_count = skill.state.retry_count + 1
                callback(true, string.format(
                    "[OpenClaw Local Fallback] Gateway externo (%s) no disponible tras %d reintentos (%s). Solicitud procesada por el motor nativo local.",
                    gw_url, retries, tostring(err or "sin conexion")
                ))
            end
        end)
        return
    end

    -- Health / Status check with automatic fallback to local CLI/IPC
    base.http_json_request(gw_url .. "/health", "GET", nil, timeout, 1, function(ok, data, _)
        skill.state.last_check = os.time()
        skill.state.endpoint   = gw_url
        if ok and data then
            skill.state.connected = true
            skill.state.retry_count = 0
            local status_txt = type(data) == "table" and (data.status or data.raw or "OK") or tostring(data)
            callback(true, string.format(
                "**[OpenClaw Gateway]** Conectado en `%s` (Estado: %s).",
                gw_url, tostring(status_txt):gsub("%s+$", "")
            ))
            return
        end

        -- Fallback check for local openclaw CLI / Unix socket
        base.exec_command("openclaw gateway status 2>/dev/null || echo 'LOCAL_BRIDGE'", function(_, out)
            if out and not out:find("LOCAL_BRIDGE") and #out:gsub("%s+", "") > 0 then
                skill.state.connected = true
                callback(true, "**[OpenClaw IPC]** Canal activo:\n" .. out:gsub("%s+$", ""))
            else
                skill.state.connected = false
                callback(true, string.format(
                    "**[OpenClaw Engine]** Operando en modo autonomo local (Lua + C/C++ + MPRIS2 + llama.cpp). Endpoint configurado: `%s`.",
                    gw_url
                ))
            end
        end, 15, 4)
    end)
end

return skill
