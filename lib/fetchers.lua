----------------------------------------------------------------------
-- fetchers.lua  –  Async internet data fetcher & random fact generator
--                  Fetches USD, EUR, Crypto (BTC/ETH/SOL), Weather,
--                  System Hardware stats, and Music every 5 minutes.
----------------------------------------------------------------------
local lgi       = require("lgi")
local GLib      = lgi.GLib
local Gio       = lgi.Gio

local config    = require("config")
local json      = require("json")
local mpris     = require("mpris")

local fetchers = {}

-- Cache of live data categories
fetchers.data = {
    clock       = "",
    greeting    = nil,
    weather     = nil,
    forex_usd   = nil,
    forex_eur   = nil,
    crypto_btc  = nil,
    crypto_eth  = nil,
    crypto_sol  = nil,
    system_ram  = nil,
    system_cpu  = nil,
    music       = nil,
    tech_tip    = nil,
}

fetchers.on_update = nil
local last_category = ""

-- Pool of interesting tech tips and curiosities
local tech_tips = {
    "💡 Tip: Con Super+T abres la terminal en Pop!_OS",
    "⚡ OpenClaw: El agente que realmente hace cosas en tu OS 🦞",
    "🐧 Pop!_OS 24.04: Basado en el kernel Linux más reciente",
    "⌨ Atajo: Super+Y abre el lanzador de aplicaciones COSMIC",
    "🎧 YouTube Music: Clic central en el avatar abre el reproductor",
    "💬 Chat: Usa /sys para ver diagnóstico instantáneo de hardware",
    "🚀 Lua: El lenguaje embebido más rápido y ligero del mundo",
    "🛡 OpenClaw: Tus datos e historial se procesan 100% en local",
    "🎵 MiniPlayer: Arrastra la barra para mover el tiempo de la canción",
    "⚙ Ollama: Qwen3 está corriendo como modelo local",
}

----------------------------------------------------------------------
-- Number formatting with commas (e.g. 83,113)
----------------------------------------------------------------------
local function format_number(n)
    if not n then return "0" end
    local s = string.format("%.0f", n)
    local pos = #s % 3
    if pos == 0 then pos = 3 end
    local parts = { s:sub(1, pos) }
    for i = pos + 1, #s, 3 do
        parts[#parts+1] = s:sub(i, i+2)
    end
    return table.concat(parts, ",")
end

----------------------------------------------------------------------
-- Internal: spawn curl async and return stdout cleanly
----------------------------------------------------------------------
local function curl_async(url, callback)
    local ok, sub = pcall(Gio.Subprocess.new,
        { "curl", "-s", "-m", "7", "--compressed", url },
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE)
    if not ok or not sub then return end

    sub:communicate_utf8_async(nil, nil, function(subprocess, result)
        local ok_fin, stdout, _ = pcall(function() return subprocess:communicate_utf8_finish(result) end)
        if ok_fin and stdout and #stdout > 0 and callback then
            callback(stdout)
        end
    end)
end

----------------------------------------------------------------------
-- 1. Clock & Contextual Greeting
----------------------------------------------------------------------
local function update_clock()
    local h = tonumber(os.date("%H")) or 12
    local m = os.date("%M")
    local ampm = h >= 12 and "pm" or "am"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end

    fetchers.data.clock = string.format("🕐 Son las %d:%s %s", h12, m, ampm)

    -- Contextual greeting depending on time of day
    if h >= 0 and h < 6 then
        fetchers.data.greeting = string.format("🌙 Son las %d:%s %s — Noche tranquila", h12, m, ampm)
    elseif h >= 6 and h < 12 then
        fetchers.data.greeting = string.format("☀️ ¡Buenos días! Son las %d:%s %s", h12, m, ampm)
    elseif h >= 12 and h < 19 then
        fetchers.data.greeting = string.format("🌤 ¡Buenas tardes! Son las %d:%s %s", h12, m, ampm)
    else
        fetchers.data.greeting = string.format("✨ ¡Buenas noches! Son las %d:%s %s", h12, m, ampm)
    end

    if fetchers.on_update then fetchers.on_update() end
    return true
end

----------------------------------------------------------------------
-- 2. Weather (wttr.in API with fallback)
----------------------------------------------------------------------
local function update_weather()
    curl_async(config.WEATHER_URL or "https://wttr.in/?format=j1", function(body)
        local d = json.decode(body)
        if d and d.current_condition and d.current_condition[1] then
            local cc = d.current_condition[1]
            local temp = cc.temp_C or "?"
            local desc = ""
            if cc.weatherDesc and cc.weatherDesc[1] then
                desc = cc.weatherDesc[1].value or ""
            end

            local emoji = "🌤"
            local dl = desc:lower()
            if dl:find("rain") or dl:find("lluvia") then emoji = "🌧"
            elseif dl:find("cloud") or dl:find("nub") or dl:find("overcast") then emoji = "☁"
            elseif dl:find("sun") or dl:find("clear") or dl:find("sol") then emoji = "☀"
            elseif dl:find("snow") or dl:find("niev") then emoji = "❄"
            elseif dl:find("thunder") or dl:find("torm") then emoji = "⛈"
            elseif dl:find("fog") or dl:find("nieb") then emoji = "🌫"
            end

            local hum = cc.humidity and (", Humedad " .. cc.humidity .. "%") or ""
            fetchers.data.weather = string.format("%s Clima: %s°C %s%s", emoji, temp, desc:gsub("%s+$", ""), hum)
        else
            -- Compact fallback
            curl_async("https://wttr.in/?format=%C+%t", function(short_text)
                if short_text and #short_text > 0 then
                    fetchers.data.weather = "🌤 Clima: " .. short_text:gsub("[\r\n]+", "")
                end
            end)
        end
        if fetchers.on_update then fetchers.on_update() end
    end)
    return true
end

----------------------------------------------------------------------
-- 3. Crypto (CoinGecko with Binance fallback)
----------------------------------------------------------------------
local function update_crypto()
    curl_async(config.CRYPTO_URL, function(body)
        local d = json.decode(body)
        if d then
            -- Bitcoin
            if d.bitcoin then
                local usd = d.bitcoin.usd or 0
                local chg = d.bitcoin.usd_24h_change or 0
                local arrow = chg >= 0 and "↑" or "↓"
                local icon = chg >= 0 and "📈" or "📉"
                fetchers.data.crypto_btc = string.format(
                    "🪙 BTC: $%s USD (%s %s%.1f%%)",
                    format_number(usd), icon, arrow, math.abs(chg))
            end

            -- Ethereum
            if d.ethereum then
                local usd = d.ethereum.usd or 0
                local chg = d.ethereum.usd_24h_change or 0
                local arrow = chg >= 0 and "↑" or "↓"
                fetchers.data.crypto_eth = string.format(
                    "💎 ETH: $%s USD (%s%.1f%%)",
                    format_number(usd), arrow, math.abs(chg))
            end

            -- Solana
            if d.solana then
                local usd = d.solana.usd or 0
                local chg = d.solana.usd_24h_change or 0
                local arrow = chg >= 0 and "↑" or "↓"
                fetchers.data.crypto_sol = string.format(
                    "⚡ SOL: $%.1f USD (%s%.1f%%)",
                    usd, arrow, math.abs(chg))
            end
        else
            -- Binance fallback for BTC
            curl_async(config.CRYPTO_FALLBACK_URL or "https://api.binance.com/api/v3/ticker/24hr?symbol=BTCUSDT", function(binance_body)
                local bd = json.decode(binance_body)
                if bd and bd.lastPrice then
                    local p = tonumber(bd.lastPrice) or 0
                    local chg = tonumber(bd.priceChangePercent) or 0
                    local arrow = chg >= 0 and "↑" or "↓"
                    fetchers.data.crypto_btc = string.format("🪙 BTC: $%s USD (%s%.1f%%)", format_number(p), arrow, math.abs(chg))
                end
            end)
        end
        if fetchers.on_update then fetchers.on_update() end
    end)
    return true
end

----------------------------------------------------------------------
-- 4. Forex (USD and EUR to MXN via open.er-api)
----------------------------------------------------------------------
local function update_forex()
    curl_async(config.FOREX_URL or "https://open.er-api.com/v6/latest/USD", function(body)
        local d = json.decode(body)
        if d and d.rates and d.rates.MXN then
            local usd_mxn = d.rates.MXN
            fetchers.data.forex_usd = string.format("💵 Dólar: $%.2f MXN", usd_mxn)

            if d.rates.EUR then
                -- 1 EUR in MXN = (USD to MXN) / (USD to EUR)
                local eur_mxn = usd_mxn / d.rates.EUR
                fetchers.data.forex_eur = string.format("💶 Euro: $%.2f MXN", eur_mxn)
            end
        else
            -- Fallback
            curl_async("https://api.frankfurter.app/latest?from=USD&to=MXN", function(fb)
                local fd = json.decode(fb)
                if fd and fd.rates and fd.rates.MXN then
                    fetchers.data.forex_usd = string.format("💵 Dólar: $%.2f MXN", fd.rates.MXN)
                end
            end)
        end
        if fetchers.on_update then fetchers.on_update() end
    end)
    return true
end

----------------------------------------------------------------------
-- 5. System Stats (RAM & CPU from /proc/)
----------------------------------------------------------------------
local function update_system_stats()
    -- RAM from /proc/meminfo
    local f = io.open("/proc/meminfo", "r")
    if f then
        local mem = f:read("*a")
        f:close()
        local total = tonumber(mem:match("MemTotal:%s*(%d+)"))
        local avail = tonumber(mem:match("MemAvailable:%s*(%d+)"))
        if total and avail then
            local free_gb = avail / 1048576
            local used_pct = ((total - avail) / total) * 100
            fetchers.data.system_ram = string.format("🧠 RAM: %.1f GB libres (%.0f%% en uso)", free_gb, used_pct)
        end
    end

    -- CPU Load from /proc/loadavg
    local lf = io.open("/proc/loadavg", "r")
    if lf then
        local load = lf:read("*a")
        lf:close()
        local l1 = load:match("^(%S+)")
        if l1 then
            fetchers.data.system_cpu = string.format("⚡ CPU: Carga %s en Pop!_OS", l1)
        end
    end
end

----------------------------------------------------------------------
-- Periodic full refresh of all internet sources (every 5 minutes)
----------------------------------------------------------------------
function fetchers.update_all_internet()
    update_forex()
    update_crypto()
    update_weather()
    update_system_stats()
    return true
end

----------------------------------------------------------------------
-- Smart Random Fact Generator for Floating Bubbles
----------------------------------------------------------------------
function fetchers.get_random_fact()
    update_system_stats()

    local candidates = {}

    local function add(cat, text)
        if text and #text > 0 and cat ~= last_category then
            candidates[#candidates+1] = { cat = cat, text = text }
        end
    end

    -- 1. Dólar & Euro
    add("forex_usd", fetchers.data.forex_usd)
    add("forex_eur", fetchers.data.forex_eur)

    -- 2. Criptos (BTC, ETH, SOL)
    add("crypto_btc", fetchers.data.crypto_btc)
    add("crypto_eth", fetchers.data.crypto_eth)
    add("crypto_sol", fetchers.data.crypto_sol)

    -- 3. Clima
    add("weather", fetchers.data.weather)

    -- 4. YouTube Music (si está sonando)
    if mpris.track.status == "Playing" and #mpris.track.title > 0 then
        local song_text = "🎵 " .. mpris.track.title
        if #mpris.track.artist > 0 then
            song_text = song_text .. " — " .. mpris.track.artist
        end
        add("music", song_text)
    end

    -- 5. Hardware / Sistema
    add("system_ram", fetchers.data.system_ram)
    add("system_cpu", fetchers.data.system_cpu)

    -- 6. Tips y curiosidades
    local random_tip = tech_tips[math.random(1, #tech_tips)]
    add("tech_tip", random_tip)

    -- 7. Saludo contextual
    add("greeting", fetchers.data.greeting)

    -- Si por alguna razón la lista quedó vacía tras excluir last_category, permitimos cualquiera
    if #candidates == 0 then
        if fetchers.data.forex_usd then return fetchers.data.forex_usd end
        if fetchers.data.crypto_btc then return fetchers.data.crypto_btc end
        if fetchers.data.weather then return fetchers.data.weather end
        return fetchers.data.clock or "✨ Pop!_OS Qwen Widget"
    end

    -- Seleccionar uno aleatorio del pool de candidatos
    local pick = candidates[math.random(1, #candidates)]
    last_category = pick.cat
    return pick.text
end

----------------------------------------------------------------------
-- Start periodic background fetchers
----------------------------------------------------------------------
function fetchers.start()
    math.randomseed(os.time())

    -- Reloj local: cada segundo
    update_clock()
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.CLOCK_INTERVAL or 1000, update_clock)

    -- Primera consulta a internet al iniciar de inmediato
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 100, function()
        update_system_stats()
        update_forex()
        update_crypto()
        update_weather()
        return false
    end)

    -- Refresco completo desde internet CADA 5 MINUTOS (300,000 ms)
    local internet_interval = config.DATA_FETCH_INTERVAL or 300000
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, internet_interval, fetchers.update_all_internet)
end

return fetchers
