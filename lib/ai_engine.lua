-- ============================================================================
-- lib/ai_engine.lua - Unified AI Inference Engine (llama.cpp + Cloud APIs)
-- Replaces Ollama with embedded llama.cpp (< 500 MB RAM budget) and native
-- Cloud API providers (OpenAI, Gemini, Anthropic, OpenRouter, Custom).
-- ============================================================================

local lgi       = require("lgi")
local GLib      = lgi.require("GLib", "2.0")
local Gio       = lgi.require("Gio", "2.0")
local json      = require("json")
local config    = require("config")
local model_mgr = require("model_manager")

local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local M = {}

local SECRETS_DIR  = (os.getenv("HOME") or ".") .. "/.config/qwen-widget"
local SECRETS_FILE = SECRETS_DIR .. "/secrets.json"
local LLAMA_PORT   = 18089
local LLAMA_URL    = "http://127.0.0.1:" .. tostring(LLAMA_PORT)

M.CLOUD_PROVIDERS = {
    openai = {
        label         = "OpenAI",
        endpoint      = "https://api.openai.com/v1/chat/completions",
        default_model = "gpt-4o-mini",
    },
    gemini = {
        label         = "Google Gemini",
        endpoint      = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        default_model = "gemini-2.5-flash",
    },
    anthropic = {
        label         = "Anthropic Claude",
        endpoint      = "https://api.anthropic.com/v1/messages",
        default_model = "claude-3-5-haiku-latest",
    },
    openrouter = {
        label         = "OpenRouter",
        endpoint      = "https://openrouter.ai/api/v1/chat/completions",
        default_model = "qwen/qwen3-8b:free",
    },
    custom = {
        label         = "Endpoint Compatible OpenAI",
        endpoint      = "https://api.openai.com/v1/chat/completions",
        default_model = "gpt-4o-mini",
    },
}

local secrets_cache = nil
local active_proc   = nil
local chat_history  = {}
local MAX_HISTORY   = 8

local function load_secrets()
    if secrets_cache then return secrets_cache end
    secrets_cache = {}
    local f = io.open(SECRETS_FILE, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" then
            secrets_cache = data
        end
    end
    return secrets_cache
end

function M.get_cloud_token(provider)
    local p = provider or config.cloud_provider or "openai"
    local s = load_secrets()
    return s[p] or ""
end

function M.set_cloud_token(provider, token_val)
    local p = provider or config.cloud_provider or "openai"
    local s = load_secrets()
    s[p] = tostring(token_val or ""):gsub("^%s+", ""):gsub("%s+$", "")
    GLib.mkdir_with_parents(SECRETS_DIR, 448) -- 0700
    local f = io.open(SECRETS_FILE, "w")
    if f then
        f:write(json.encode(s))
        f:close()
        os.execute("chmod 600 '" .. SECRETS_FILE .. "' 2>/dev/null")
    end
end

-- Clean <think>...</think> blocks emitted by Qwen3 reasoning models
local function clean_output(text)
    if not text then return "" end
    local cleaned = text:gsub("<think>.-</think>%s*", "")
    cleaned = cleaned:gsub("^<think>.*", "")
    return cleaned:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Ensure local llama.cpp server is running with the requested GGUF model
function M.ensure_local_model(role, callback)
    local target_role = (role == "grammar") and "grammar" or "chat"
    local filename
    if target_role == "grammar" then
        filename = config.grammar_model or "es-grammar.gguf"
    else
        filename = config.chat_model or "qwen3.0-0.8b.gguf"
    end

    local model_path = model_mgr.get_model_path(filename)
    local valid = model_mgr.verify_model(model_path)
    if not valid then
        local alt_path = model_mgr.get_model_path(
            (target_role == "grammar") and "qwen3.0-0.8b.gguf" or "es-grammar.gguf"
        )
        if model_mgr.verify_model(alt_path) then
            model_path = alt_path
        else
            model_mgr.download_model(target_role, nil, function(ok_dl, path_or_err)
                if ok_dl then
                    M.ensure_local_model(role, callback)
                elseif callback then
                    callback(false, "Descargando modelo GGUF: " .. tostring(path_or_err))
                end
            end)
            return
        end
    end

    local ctx_size = tonumber(config.ctx_size) or 512
    local threads  = tonumber(config.threads) or 4

    if qwen_native and qwen_native.llama_ensure then
        local ok_start = qwen_native.llama_ensure(model_path, ctx_size, threads)
        if not ok_start then
            if callback then callback(false, "No se pudo iniciar llama.cpp embebido") end
            return
        end
    end

    local attempts = 0
    local function check_ready()
        attempts = attempts + 1
        local st = qwen_native and qwen_native.llama_status and qwen_native.llama_status() or nil
        if st and st.ready then
            if callback then callback(true, LLAMA_URL) end
            return false
        end

        local ok_sub, proc = pcall(function()
            return Gio.Subprocess.new(
                { "curl", "-s", "-m", "1", LLAMA_URL .. "/health" },
                Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE
            )
        end)
        if not ok_sub or not proc then
            if callback then callback(false, "Error verificando llama.cpp") end
            return false
        end

        proc:communicate_utf8_async(nil, nil, function(p, res)
            local ok_c, out = pcall(function() return p:communicate_utf8_finish(res) end)
            if ok_c and out and out:find('"ok"') then
                if callback then callback(true, LLAMA_URL) end
            elseif attempts < 40 then
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, check_ready)
            else
                if callback then callback(false, "Tiempo de espera agotado iniciando llama.cpp") end
            end
        end)
        return false
    end

    check_ready()
end

-- Execute HTTP request asynchronously via curl subprocess
local function async_http_json(url, headers, payload_tbl, timeout_sec, callback)
    local body_str = json.encode(payload_tbl)
    local argv = {
        "curl", "-s", "-S", "--max-time", tostring(timeout_sec or 35),
        "-X", "POST", url,
        "-H", "Content-Type: application/json",
    }
    for _, h in ipairs(headers or {}) do
        table.insert(argv, "-H")
        table.insert(argv, h)
    end
    table.insert(argv, "-d")
    table.insert(argv, body_str)

    local ok_sub, proc = pcall(function()
        return Gio.Subprocess.new(
            argv,
            Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_PIPE
        )
    end)
    if not ok_sub or not proc then
        callback(nil, "No se pudo iniciar peticion HTTP")
        return
    end
    active_proc = proc

    proc:communicate_utf8_async(nil, nil, function(p, res)
        if active_proc == p then active_proc = nil end
        local ok_c, stdout, stderr = pcall(function()
            return p:communicate_utf8_finish(res)
        end)
        if qwen_native and qwen_native.trim_memory then
            pcall(qwen_native.trim_memory)
        end
        if not ok_c or not stdout or stdout == "" then
            callback(nil, (stderr and stderr ~= "") and stderr or "Sin respuesta del motor de inferencia")
            return
        end
        local ok_j, decoded = pcall(json.decode, stdout)
        if not ok_j or type(decoded) ~= "table" then
            callback(nil, "Respuesta JSON invalida: " .. stdout:sub(1, 120))
            return
        end
        if decoded.error then
            local msg = type(decoded.error) == "table" and (decoded.error.message or "Error de inferencia") or tostring(decoded.error)
            callback(nil, msg)
            return
        end
        callback(decoded, nil)
    end)
end

-- Cloud inference call
local function run_cloud_completion(messages, opts, callback)
    local provider_id = config.cloud_provider or "openai"
    local pinfo = M.CLOUD_PROVIDERS[provider_id] or M.CLOUD_PROVIDERS.openai
    local token = M.get_cloud_token(provider_id)
    if token == "" then
        callback(nil, "Clave de API Cloud no configurada para " .. pinfo.label .. ". Abre Configuracion > API Cloud.")
        return
    end

    local model = config.cloud_model
    if not model or model == "" then
        model = pinfo.default_model
    end

    local url = pinfo.endpoint
    if provider_id == "custom" and config.cloud_endpoint and config.cloud_endpoint ~= "" then
        url = config.cloud_endpoint
    end

    if provider_id == "anthropic" then
        local sys_prompt = ""
        local user_msgs = {}
        for _, m in ipairs(messages) do
            if m.role == "system" then
                sys_prompt = m.content
            else
                table.insert(user_msgs, { role = m.role, content = m.content })
            end
        end
        local headers = {
            "x-api-key: " .. token,
            "anthropic-version: 2023-06-01",
        }
        local payload = {
            model      = model,
            max_tokens = (opts and opts.max_tokens) or 512,
            system     = sys_prompt ~= "" and sys_prompt or nil,
            messages   = user_msgs,
        }
        async_http_json(url, headers, payload, 35, function(data, err)
            if not data then
                callback(nil, err)
                return
            end
            local text = ""
            if type(data.content) == "table" and data.content[1] then
                text = data.content[1].text or ""
            end
            callback(clean_output(text), nil)
        end)
    else
        local headers = {
            "Authorization: Bearer " .. token,
        }
        local payload = {
            model       = model,
            messages    = messages,
            temperature = (opts and opts.temperature) or 0.4,
            max_tokens  = (opts and opts.max_tokens) or 512,
            stream      = false,
        }
        async_http_json(url, headers, payload, 35, function(data, err)
            if not data then
                callback(nil, err)
                return
            end
            local text = ""
            if type(data.choices) == "table" and data.choices[1] and data.choices[1].message then
                text = data.choices[1].message.content or ""
            end
            callback(clean_output(text), nil)
        end)
    end
end

-- Local llama.cpp inference call
local function run_local_completion(messages, opts, callback)
    local role = (opts and opts.role) or "chat"
    M.ensure_local_model(role, function(ok, url_or_err)
        if not ok then
            callback(nil, url_or_err)
            return
        end

        local formatted_msgs = {}
        for i, m in ipairs(messages) do
            local content = m.content or ""
            if i == #messages and m.role == "user" and not content:find("/no_think") then
                content = content .. " /no_think"
            end
            table.insert(formatted_msgs, { role = m.role, content = content })
        end

        local payload = {
            messages    = formatted_msgs,
            temperature = (opts and opts.temperature) or 0.3,
            max_tokens  = (opts and opts.max_tokens) or 256,
            stream      = false,
        }

        async_http_json(LLAMA_URL .. "/v1/chat/completions", {}, payload, 45, function(data, err)
            if not data then
                callback(nil, err)
                return
            end
            local text = ""
            if type(data.choices) == "table" and data.choices[1] and data.choices[1].message then
                text = data.choices[1].message.content or ""
            end
            callback(clean_output(text), nil)
        end)
    end)
end

-- Unified chat/grammar completion entry point
function M.chat(messages, opts, callback)
    if type(opts) == "function" then
        callback = opts
        opts = {}
    end
    opts = opts or {}

    local mode = opts.provider or config.inference_provider or "local"
    if mode == "cloud" then
        run_cloud_completion(messages, opts, function(reply, err)
            if reply then
                callback(reply, nil)
            elseif opts.fallback_local ~= false then
                run_local_completion(messages, opts, callback)
            else
                callback(nil, err)
            end
        end)
    else
        run_local_completion(messages, opts, callback)
    end
end

-- Conversational send with streaming token callback (used by chat.lua)
function M.send(user_text, on_token, on_error)
    local ok_oc, openclaw = pcall(require, "openclaw_agent")
    local sys_prompt = (ok_oc and openclaw and openclaw.get_system_prompt)
        and openclaw.get_system_prompt()
        or "Eres Qwen AI, un asistente de escritorio conciso y preciso. Responde siempre en espanol de forma directa."

    table.insert(chat_history, { role = "user", content = user_text })
    while #chat_history > MAX_HISTORY do
        table.remove(chat_history, 1)
    end

    local msgs = { { role = "system", content = sys_prompt } }
    for _, h in ipairs(chat_history) do
        table.insert(msgs, { role = h.role, content = h.content })
    end

    M.chat(msgs, { role = "chat", max_tokens = 320, temperature = 0.4 }, function(reply, err)
        if not reply then
            if on_error then on_error(err or "Error en inferencia") end
            return
        end

        table.insert(chat_history, { role = "assistant", content = reply })

        if not on_token then return end
        -- Stream chunks progressively to UI for smooth visual feedback
        local total_len = #reply
        if total_len <= 16 then
            on_token(reply, false)
            on_token("", true)
            return
        end

        local pos = 1
        local step = math.max(10, math.floor(total_len / 16))
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 18, function()
            local next_pos = math.min(total_len, pos + step - 1)
            local chunk = reply:sub(pos, next_pos)
            on_token(chunk, false)
            pos = next_pos + 1
            if pos > total_len then
                on_token("", true)
                return false
            end
            return true
        end)
    end)
end

function M.clear()
    chat_history = {}
    if qwen_native and qwen_native.trim_memory then
        pcall(qwen_native.trim_memory)
    end
    collectgarbage("collect")
end

function M.cancel()
    if active_proc then
        pcall(function() active_proc:force_exit() end)
        active_proc = nil
    end
end

-- Dedicated Spanish/Multilingual grammar transformation using es-grammar.gguf
function M.transform_text(instruction, input_text, callback)
    local sys = "Eres es-grammar, un motor experto en gramatica, ortografia y estilo del idioma espanol. Procesa el texto del usuario segun la instruccion solicitada. Devuelve UNICAMENTE el texto corregido o transformado, sin saludos, sin explicaciones y sin comillas adicionales."
    local prompt = string.format("%s:\n%s", instruction, input_text)
    local messages = {
        { role = "system", content = sys },
        { role = "user",   content = prompt },
    }
    M.chat(messages, {
        role        = "grammar",
        temperature = 0.15,
        max_tokens  = 256,
    }, function(reply, err)
        if reply and #reply > 0 then
            local clean = reply:gsub("^%s*[\"']*", ""):gsub("[\"']*%s*$", "")
            callback(true, clean)
        else
            callback(false, err or "Sin respuesta del modelo gramatical")
        end
    end)
end

function M.get_status()
    local mem = (qwen_native and qwen_native.get_memory_stats) and qwen_native.get_memory_stats() or {
        widget_rss_mb = 25.0,
        llama_rss_mb  = 0.0,
        total_rss_mb  = 25.0,
        budget_mb     = 500.0,
        within_budget = true,
    }
    local llama = (qwen_native and qwen_native.llama_status) and qwen_native.llama_status() or {
        running = false,
        ready   = false,
        model   = "",
    }
    return {
        provider       = config.inference_provider or "local",
        cloud_provider = config.cloud_provider or "openai",
        memory         = mem,
        llama          = llama,
        models         = model_mgr.status(),
    }
end

function M.stop_local()
    if qwen_native and qwen_native.llama_stop then
        qwen_native.llama_stop()
    end
end

return M
