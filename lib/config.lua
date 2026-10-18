----------------------------------------------------------------------
-- config.lua  –  Configuracion centralizada y persistente para Qwen-Widget
--                Arquitectura Hibrida Lua + C/C++, llama.cpp y Cloud API
----------------------------------------------------------------------
local config = {}

local ok_j, json = pcall(require, "json")
if not ok_j then json = nil end

----------- Paths (se sobreescriben en main.lua) ---------------------
config.BASE_DIR    = os.getenv("QWEN_WIDGET_DIR") or "/opt/qwen-widget"
config.ASSETS_DIR  = config.BASE_DIR .. "/assets"
config.AVATAR      = config.ASSETS_DIR .. "/avatar.jpg"
config.CONFIG_PATH = (os.getenv("HOME") or "/home/alex") .. "/.config/qwen-widget/config.json"

----------- Configuracion de Modelos e Inferencia (llama.cpp + Cloud)
config.inference_provider = "local"              -- "local" (llama.cpp) | "cloud"
config.backend_mode       = "llama"              -- Embebido llama.cpp por defecto
config.chat_model         = "qwen3.0-0.8b.gguf"  -- Modelo conversacional GGUF (0.8b)
config.grammar_model      = "es-grammar.gguf"    -- Modelo corrector gramatical GGUF
config.llama_model        = "qwen3.0-0.8b.gguf"
config.ollama_model       = "qwen3.0-0.8b.gguf"  -- Alias de compatibilidad
config.threads            = 4                    -- Hilos CPU
config.ctx_size           = 512                  -- Contexto optimizado (<= 500 MB RAM)
config.kv_quant           = "q4_0"               -- Cuantizacion de cache KV
config.ram_limit          = "500MB"              -- Presupuesto estricto <= 500 MB

----------- Configuracion Cloud API ----------------------------------
config.cloud_provider     = "openai"             -- "openai" | "gemini" | "anthropic" | "openrouter" | "custom"
config.cloud_model        = "gpt-4o-mini"
config.cloud_endpoint     = "https://api.openai.com/v1/chat/completions"

----------- Musica y Letras Sincronizadas (YT Music + Spotify) -------
config.music_source       = "auto"               -- "auto" | "ytmusic" | "spotify"
config.lyrics_offset_ms   = 0                    -- Ajuste fino de sincronizacion en ms

----------- Habilidades del Widget y Menu Global ---------------------
config.skills = {
    -- Menu Global Autodesplegable al seleccionar texto (C/C++ Native Hook)
    global_text_menu = true,

    -- Habilidades individuales de escritura (es-grammar.gguf)
    skill_formalize = true,
    skill_spelling  = true,
    skill_expand    = true,
    skill_summarize = true,
    skill_humanize  = true,
    skill_simplify  = true,
    skill_grammar   = true,

    -- Habilidades operativas del agente (OpenClaw)
    system_info      = true,
    bash             = true,
    media_control    = true,
    web_search       = true,
    app_launch       = true,
    screenshot       = true,
    notify           = true,
    openclaw_gateway = true,

    -- Componentes de interfaz del widget
    data_bubbles     = true,
    lyrics           = true,
    player           = true,
}

----------- Bubble (circulo flotante con sprites de estado) ----------
config.BUBBLE_SIZE    = 72
config.BUBBLE_MARGIN  = 8
config.BUBBLE_RADIUS  = 36
config.GLOW_WIDTH     = 2

----------- Launcher radial ------------------------------------------
config.LAUNCHER_ENABLED  = false
config.LAUNCHER_RADIUS   = 80
config.LAUNCHER_SPAN_DEG = 185
config.LAUNCHER_BTN_SIZE = 42
config.LAUNCHER_HOVER_MS = 200
config.LAUNCHER_LEAVE_MS = 450
config.LAUNCHER_ANIM_MS  = 300

----------- Chat panel -----------------------------------------------
config.CHAT_W      = 400
config.CHAT_H      = 510
config.CHAT_GAP    = 12
config.CHAT_RADIUS = 16

----------- Data bubbles (burbujas de datos dinamicas) ---------------
config.DBUBBLE_MAX_TEXT_W = 290
config.DBUBBLE_SHOW_MS    = 12000
config.DBUBBLE_CYCLE_MS   = 60000
config.DBUBBLE_FADE_MS    = 200

----------- Sistema de Diseno y Contraste Garantizado ----------------
config.BG           = { 0.067, 0.075, 0.118, 0.96 } -- #11131E
config.BG_CHAT      = { 0.067, 0.075, 0.118, 0.97 }
config.BG_DBUBBLE   = { 0.075, 0.082, 0.133, 0.96 }
config.TEXT         = { 0.960, 0.970, 0.990, 1.0  } -- #F5F7FC
config.TEXT_DIM     = { 0.640, 0.680, 0.780, 1.0  } -- #A3AED0
config.ACCENT       = { 0.380, 0.540, 0.980, 1.0  } -- #618AFA
config.ACCENT_PINK  = { 0.925, 0.365, 0.640, 1.0  } -- #EC5DA3
config.ACCENT_CYAN  = { 0.133, 0.827, 0.933, 1.0  } -- #22D3EE
config.INPUT_BG     = { 0.110, 0.122, 0.188, 0.96 }
config.NOTIFICATION = { 0.960, 0.620, 0.043, 1.0  }

-- Variables explicitas de alto contraste para menus y botones
config.CONTRAST = {
    normal   = { background = "#11131E", foreground = "#F8FAFC", border = "#334155" },
    hover    = { background = "#F8FAFC", foreground = "#090A10", border = "#FFFFFF" },
    active   = { background = "#3B82F6", foreground = "#FFFFFF", border = "#60A5FA" },
    disabled = { background = "#1E2235", foreground = "#94A3B8", border = "#283048" },
}

----------- Fonts (con fallback seguro) ------------------------------
config.FONT_DATA    = "Sans 11"
config.FONT_LABEL   = "Sans Bold 9"
config.FONT_CHAT    = "Sans 11.5"
config.FONT_INPUT   = "Sans 11.5"
config.FONT_NOTIF   = "Sans Bold 10"
config.FONT_DBUBBLE = "Sans 10.5"

----------- Data refresh intervals (ms) ------------------------------
config.CLOCK_INTERVAL      = 1000
config.DATA_FETCH_INTERVAL = 300000

----------- API endpoints --------------------------------------------
config.WEATHER_URL         = "https://wttr.in/?format=j1"
config.CRYPTO_URL          = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,solana&vs_currencies=mxn,usd&include_24hr_change=true"
config.CRYPTO_FALLBACK_URL = "https://api.binance.com/api/v3/ticker/24hr?symbol=BTCUSDT"
config.FOREX_URL           = "https://open.er-api.com/v6/latest/USD"

----------- Compatibilidad -------------------------------------------
config.OLLAMA_URL   = "http://127.0.0.1:18089/v1/chat/completions"
config.OLLAMA_MODEL = config.chat_model

----------- Animations -----------------------------------------------
config.FADE_DURATION_MS = 280
config.SNAP_DURATION_MS = 220
config.ANIM_FPS         = 60
config.SNAP_THRESHOLD   = 50

----------- DBus / KDE Connect ---------------------------------------
config.KDECONNECT_BUS   = "org.kde.kdeconnect"
config.NOTIF_TIMEOUT_MS = 8000

----------- YouTube Music + Spotify Mini Player ----------------------
config.PLAYER_W            = 372
config.PLAYER_H            = 192
config.PLAYER_RADIUS       = 15
config.PLAYER_GAP          = 10
config.PLAYER_AUTO_HIDE_MS = 14000
config.PLAYER_COVER_SIZE   = 68
config.PLAYER_UPDATE_MS    = 250

----------- Letras Sincronizadas (YT Music + Spotify) ----------------
config.LYRICS_ENABLED = config.skills.lyrics
config.LYRICS_MAX_W   = 330
config.LYRICS_MIN_W   = 130
config.FONT_LYRICS    = "Sans Bold 11"
config.BG_LYRICS      = { 0.07, 0.08, 0.14, 0.95 }
config.BORDER_LYRICS  = { 0.925, 0.365, 0.640, 0.85 }
config.LYRICS_GAP     = 8
config.LYRICS_FADE_MS = 160

----------- OpenClaw Agent -------------------------------------------
config.OPENCLAW_AGENT_MODE  = true
config.OPENCLAW_GATEWAY_URL = "http://127.0.0.1:18789"
config.OPENCLAW_TIMEOUT_SEC = 6
config.OPENCLAW_RETRIES     = 2
config.AGENT_NAME           = "OpenClaw-Qwen"
config.AGENT_VERSION        = "2.0-native"

----------- Getters / Setters seguros --------------------------------
function config.get(key, default_val)
    if config[key] ~= nil then
        return config[key]
    end
    if config.skills and config.skills[key] ~= nil then
        return config.skills[key]
    end
    return default_val
end

function config.set(key, val)
    if config.skills and config.skills[key] ~= nil and type(val) == "boolean" then
        config.skills[key] = val
    else
        config[key] = val
    end
    config.notify_change(key, val)
end

----------- Listeners para actualizacion en caliente -----------------
config._listeners = {}

function config.add_listener(fn)
    if type(fn) == "function" then
        table.insert(config._listeners, fn)
    end
end

function config.notify_change(key, value)
    config.OLLAMA_MODEL   = config.chat_model
    config.LYRICS_ENABLED = (config.skills.lyrics == true)
    for _, fn in ipairs(config._listeners) do
        pcall(fn, key, value)
    end
end

----------- Persistencia Ligera --------------------------------------
function config.save()
    if not json then
        local ok, j = pcall(require, "json")
        if ok then json = j end
    end
    if not json then return false end

    local payload = {
        inference_provider = config.inference_provider,
        backend_mode       = config.backend_mode,
        chat_model         = config.chat_model,
        grammar_model      = config.grammar_model,
        llama_model        = config.llama_model,
        ollama_model       = config.ollama_model,
        threads            = config.threads,
        ctx_size           = config.ctx_size,
        kv_quant           = config.kv_quant,
        ram_limit          = config.ram_limit,
        cloud_provider     = config.cloud_provider,
        cloud_model        = config.cloud_model,
        cloud_endpoint     = config.cloud_endpoint,
        music_source       = config.music_source,
        lyrics_offset_ms   = config.lyrics_offset_ms,
        OPENCLAW_GATEWAY_URL = config.OPENCLAW_GATEWAY_URL,
        skills             = config.skills,
    }

    local dir = config.CONFIG_PATH:match("(.+)/[^/]+$")
    if dir then
        os.execute(string.format("mkdir -p '%s' 2>/dev/null", dir))
    end

    local f = io.open(config.CONFIG_PATH, "w")
    if f then
        f:write(json.encode(payload))
        f:close()
        payload = nil
        collectgarbage("step", 100)
        return true
    end
    return false
end

function config.load()
    local f = io.open(config.CONFIG_PATH, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()

    if not content or #content == 0 then return false end

    if not json then
        local ok, j = pcall(require, "json")
        if ok then json = j end
    end
    if not json then return false end

    local ok_d, d = pcall(json.decode, content)
    if ok_d and d and type(d) == "table" then
        if d.inference_provider then config.inference_provider = d.inference_provider end
        if d.backend_mode       then config.backend_mode       = d.backend_mode end
        if d.chat_model         then config.chat_model         = d.chat_model end
        if d.grammar_model      then config.grammar_model      = d.grammar_model end
        if d.llama_model        then config.llama_model        = d.llama_model end
        if d.threads            then config.threads            = tonumber(d.threads) or config.threads end
        if d.ctx_size           then config.ctx_size           = tonumber(d.ctx_size) or config.ctx_size end
        if d.kv_quant           then config.kv_quant           = d.kv_quant end
        if d.ram_limit          then config.ram_limit          = d.ram_limit end
        if d.cloud_provider     then config.cloud_provider     = d.cloud_provider end
        if d.cloud_model        then config.cloud_model        = d.cloud_model end
        if d.cloud_endpoint     then config.cloud_endpoint     = d.cloud_endpoint end
        if d.music_source       then config.music_source       = d.music_source end
        if d.lyrics_offset_ms   then config.lyrics_offset_ms   = tonumber(d.lyrics_offset_ms) or 0 end
        if d.OPENCLAW_GATEWAY_URL then config.OPENCLAW_GATEWAY_URL = d.OPENCLAW_GATEWAY_URL end

        if d.skills and type(d.skills) == "table" then
            for k, v in pairs(d.skills) do
                config.skills[k] = (v == true)
            end
        end

        -- Garantizar migracion limpia a llama.cpp si un config antiguo tenia "ollama"
        if config.backend_mode == "ollama" then
            config.backend_mode = "llama"
        end

        config.OLLAMA_MODEL   = config.chat_model
        config.LYRICS_ENABLED = (config.skills.lyrics == true)
        d = nil
        content = nil
        collectgarbage("step", 100)
        return true
    end
    return false
end

config.load()

return config
