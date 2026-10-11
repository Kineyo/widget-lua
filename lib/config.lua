----------------------------------------------------------------------
-- config.lua  –  Configuración centralizada para Qwen-Widget
----------------------------------------------------------------------
local config = {}

----------- Paths (se sobreescriben en main.lua) ---------------------
config.BASE_DIR   = "/opt/qwen-widget"
config.ASSETS_DIR = config.BASE_DIR .. "/assets"
config.AVATAR     = config.ASSETS_DIR .. "/avatar.jpg"

----------- Bubble (círculo flotante minimalista) --------------------
config.BUBBLE_SIZE    = 70       -- diámetro del círculo
config.BUBBLE_MARGIN  = 8        -- gap mínimo desde el borde
config.BUBBLE_RADIUS  = 35       -- radio = SIZE/2
config.GLOW_WIDTH     = 2        -- grosor de línea de borde fino

----------- Launcher radial (desactivado por estilo minimalista) ------
config.LAUNCHER_ENABLED     = false
config.LAUNCHER_RADIUS      = 80    -- distancia del centro del orbe a cada botón
config.LAUNCHER_SPAN_DEG    = 185   -- apertura total del abanico (para 6 botones)
config.LAUNCHER_BTN_SIZE    = 42    -- diámetro de cada botón
config.LAUNCHER_HOVER_MS    = 200   -- retardo de "intención" antes de abrir
config.LAUNCHER_LEAVE_MS    = 450   -- tiempo antes de cerrarse al salir el mouse
config.LAUNCHER_ANIM_MS     = 300   -- duración de la animación de apertura

----------- Chat panel -----------------------------------------------
config.CHAT_W       = 380
config.CHAT_H       = 480
config.CHAT_GAP     = 12       -- separación burbuja ↔ chat
config.CHAT_RADIUS  = 18

----------- Data bubbles (burbujas de datos dinámicas) ---------------
config.DBUBBLE_MAX_TEXT_W = 290 -- ancho aceptable antes de escribir hacia abajo
config.DBUBBLE_SHOW_MS    = 12000 -- 12 segundos visibles
config.DBUBBLE_CYCLE_MS   = 60000 -- cada 60s muestra un dato aleatorio fresco
config.DBUBBLE_FADE_MS    = 200   -- duración fade in/out

----------- Colours (r, g, b, a) ------------------------------------
config.BG           = { 0.075, 0.065, 0.125, 0.96 }
config.BG_CHAT      = { 0.075, 0.065, 0.125, 0.96 }
config.BG_DBUBBLE   = { 0.080, 0.070, 0.135, 0.95 }
config.TEXT          = { 0.940, 0.940, 0.980, 1.0  }
config.TEXT_DIM      = { 0.620, 0.620, 0.750, 1.0  }
config.ACCENT        = { 0.545, 0.361, 0.965, 1.0  }  -- #8B5CF6 violeta
config.ACCENT_PINK   = { 0.957, 0.447, 0.714, 1.0  }  -- #F472B6 rosa
config.ACCENT_CYAN   = { 0.133, 0.827, 0.933, 1.0  }  -- #22D3EE cian
config.INPUT_BG      = { 0.135, 0.125, 0.205, 0.94 }
config.NOTIFICATION  = { 0.980, 0.600, 0.080, 1.0  }  -- amber

----------- Fonts ----------------------------------------------------
config.FONT_DATA     = "Sans 11"
config.FONT_LABEL    = "Sans Bold 9"
config.FONT_CHAT     = "Sans 12"
config.FONT_INPUT    = "Sans 12"
config.FONT_NOTIF    = "Sans Bold 10"
config.FONT_DBUBBLE  = "Sans 11"

----------- Data refresh intervals (ms) ------------------------------
config.CLOCK_INTERVAL       = 1000
config.DATA_FETCH_INTERVAL  = 300000  -- cada 5 minutos consulta internet (dólar, criptos, clima)

----------- API endpoints -------------------------------------------
config.WEATHER_URL         = "https://wttr.in/?format=j1"
config.CRYPTO_URL          = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,solana&vs_currencies=mxn,usd&include_24hr_change=true"
config.CRYPTO_FALLBACK_URL = "https://api.binance.com/api/v3/ticker/24hr?symbol=BTCUSDT"
config.FOREX_URL           = "https://open.er-api.com/v6/latest/USD"

----------- Ollama --------------------------------------------------
config.OLLAMA_URL   = "http://localhost:11434/api/chat"
config.OLLAMA_MODEL = os.getenv("QWEN_MODEL") or "qwen3:0.6b"

----------- Animations -----------------------------------------------
config.FADE_DURATION_MS = 350
config.SNAP_DURATION_MS = 250
config.ANIM_FPS         = 60

----------- Edge snapping -------------------------------------------
config.SNAP_THRESHOLD = 50  -- distancia para activar snap

----------- DBus / KDE Connect ---------------------------------------
config.KDECONNECT_BUS   = "org.kde.kdeconnect"
config.NOTIF_TIMEOUT_MS = 8000

----------- YouTube Music / Mini Player -------------------------------
config.PLAYER_W             = 350
config.PLAYER_H             = 138
config.PLAYER_RADIUS        = 16
config.PLAYER_GAP           = 10
config.PLAYER_AUTO_HIDE_MS  = 12000 -- 12 segundos antes de auto-ocultarse
config.PLAYER_COVER_SIZE    = 68
config.PLAYER_UPDATE_MS     = 250   -- intervalo de refresco de posición (ms)

----------- YouTube Music Lyrics (Letras sincronizadas) ----------------
config.LYRICS_ENABLED        = true
config.LYRICS_MAX_W          = 320   -- ancho máximo antes de escribir hacia abajo
config.LYRICS_MIN_W          = 130   -- ancho mínimo de la burbuja
config.FONT_LYRICS           = "Sans Bold 11"
config.BG_LYRICS             = { 0.08, 0.08, 0.15, 0.94 }
config.BORDER_LYRICS         = { 1.0,  0.412, 0.706, 0.80 } -- Rosa neón YouTube Music (#FF69B4)
config.LYRICS_GAP            = 6     -- separación sobre el widget
config.LYRICS_FADE_MS        = 180   -- animación fade suave

----------- OpenClaw Agent -------------------------------------------
config.OPENCLAW_AGENT_MODE  = true  -- Habilitar capacidades de agente
config.OPENCLAW_GATEWAY_URL = "http://127.0.0.1:18789"
config.AGENT_NAME           = "OpenClaw-Qwen"
config.AGENT_VERSION        = "2.0-lobster"

return config

