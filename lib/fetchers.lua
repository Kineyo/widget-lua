----------------------------------------------------------------------
-- fetchers.lua  –  Async internet data fetcher & system telemetry
--                  Zero emojis. Clean typographic tags.
----------------------------------------------------------------------
local lgi       = require("lgi")
local GLib      = lgi.GLib
local Gio       = lgi.Gio

local config    = require("config")
local json      = require("json")
local mpris     = require("mpris")

local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local fetchers = {}

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

function fetchers.get_backend_status()
    local provider = config.inference_provider or "local"
    local mem_str = ""
    if qwen_native and qwen_native.get_memory_stats then
        local ms = qwen_native.get_memory_stats()
        if ms and ms.total_rss_mb then
            mem_str = string.format(" | RAM Total: %.0f MB / 500 MB", ms.total_rss_mb)
        end
    end
    if provider == "cloud" then
        return string.format("[IA Cloud] Proveedor: %s (%s)%s",
            (config.cloud_provider or "openai"):upper(),
            config.cloud_model or "gpt-4o-mini",
            mem_str)
    end
    return string.format("[Motor Local llama.cpp] Chat: %s | Gramatica: %s%s",
        config.chat_model or "qwen3.0-0.8b.gguf",
        config.grammar_model or "es-grammar.gguf",
        mem_str)
end

local tech_tips = {
    "[Atajo] Con Super+T abres la terminal en Pop!_OS",
    "[OpenClaw] Agente local asincrono con integracion C/C++ y Lua",
    "[Pop!_OS] Compatible con sesiones X11 y Wayland / COSMIC",
    "[Atajo] Con Super+Y abres el lanzador de aplicaciones COSMIC",
    "[Multimedia] Clic central en la burbuja abre el reproductor YT Music / Spotify",
    "[Chat IA] Usa /sys para ver diagnostico de hardware y memoria del widget",
    "[Gramatica] Selecciona cualquier texto con el cursor para corregir al instante",
    "[Privacidad] Inferencia local embebida con llama.cpp y presupuesto <= 500 MB RAM",
    function() return fetchers.get_backend_status() end,
}

local function format_number(n)
    if not n then return "0" end
    local s = string.format("%.0f", n)
    local pos = #s % 3
    if pos == 0 then pos = 3 end
    local parts = { s:sub(1, pos) }
    for i = pos + 1, #s, 3 do
        parts[#parts + 1] = s:sub(i, i + 2)
    end
    return table.concat(parts, ",")
end

local function curl_async(url, callback)
    local ok, sub = pcall(Gio.Subprocess.new,
        { "curl", "-s", "-m", "7", "--compressed", url },
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE)
    if not ok or not sub then return end

    sub:communicate_utf8_async(nil, nil, function(subprocess, result)
        local ok_fin, stdout = pcall(function() return subprocess:communicate_utf8_finish(result) end)
        if ok_fin and stdout and #stdout > 0 and callback then
            callback(stdout)
        end
    end)
end

local function update_clock()
    local h = tonumber(os.date("%H")) or 12
    local m = os.date("%M")
    local ampm = h >= 12 and "pm" or "am"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end

    fetchers.data.clock = string.format("[Hora] %d:%s %s", h12, m, ampm)

    if h >= 0 and h < 6 then
        fetchers.data.greeting = string.format("[Hora] %d:%s %s - Madrugada", h12, m, ampm)
    elseif h >= 6 and h < 12 then
        fetchers.data.greeting = string.format("[Buenos dias] %d:%s %s", h12, m, ampm)
    elseif h >= 12 and h < 19 then
        fetchers.data.greeting = string.format("[Buenas tardes] %d:%s %s", h12, m, ampm)
    else
        fetchers.data.greeting = string.format("[Buenas noches] %d:%s %s", h12, m, ampm)
    end

    if fetchers.on_update then fetchers.on_update() end
    return true
end

local function update_weather()
    curl_async(config.WEATHER_URL or "https://wttr.in/?format=j1", function(body)
        local ok_d, d = pcall(json.decode, body)
        if ok_d and d and d.current_condition and d.current_condition[1] then
            local cc = d.current_condition[1]
            local temp = cc.temp_C or "?"
            local desc = ""
            if cc.weatherDesc and cc.weatherDesc[1] then
                desc = cc.weatherDesc[1].value or ""
            end
            local hum = cc.humidity and (", Humedad " .. cc.humidity .. "%") or ""
            fetchers.data.weather = string.format("[Clima] %s C - %s%s", temp, desc:gsub("%s+$", ""), hum)
        else
            curl_async("https://wttr.in/?format=%C+%t", function(short_text)
                if short_text and #short_text > 0 then
                    fetchers.data.weather = "[Clima] " .. short_text:gsub("[\r\n]+", "")
                end
            end)
        end
        if fetchers.on_update then fetchers.on_update() end
    end)
    return true
end

local function update_crypto()
    curl_async(config.CRYPTO_URL, function(body)
        local ok_d, d = pcall(json.decode, body)
        if ok_d and d then
            if d.bitcoin then
                local usd = d.bitcoin.usd or 0
                local chg = d.bitcoin.usd_24h_change or 0
                local sign = chg >= 0 and "+" or "-"
                fetchers.data.crypto_btc = string.format("[BTC] $%s USD (%s%.1f%%)", format_number(usd), sign, math.abs(chg))
            end
            if d.ethereum then
                local usd = d.ethereum.usd or 0
                local chg = d.ethereum.usd_24h_change or 0
                local sign = chg >= 0 and "+" or "-"
                fetchers.data.crypto_eth = string.format("[ETH] $%s USD (%s%.1f%%)", format_number(usd), sign, math.abs(chg))
            end
            if d.solana then
                local usd = d.solana.usd or 0
                local chg = d.solana.usd_24h_change or 0
                local sign = chg >= 0 and "+" or "-"
                fetchers.data.crypto_sol = string.format("[SOL] $%.1f USD (%s%.1f%%)", usd, sign, math.abs(chg))
            end
        else
            curl_async(config.CRYPTO_FALLBACK_URL or "https://api.binance.com/api/v3/ticker/24hr?symbol=BTCUSDT", function(binance_body)
                local ok_b, bd = pcall(json.decode, binance_body)
                if ok_b and bd and bd.lastPrice then
                    local p = tonumber(bd.lastPrice) or 0
                    local chg = tonumber(bd.priceChangePercent) or 0
                    local sign = chg >= 0 and "+" or "-"
                    fetchers.data.crypto_btc = string.format("[BTC] $%s USD (%s%.1f%%)", format_number(p), sign, math.abs(chg))
                end
            end)
        end
        if fetchers.on_update then fetchers.on_update() end
    end)
    return true
end

local function update_forex()
    curl_async(config.FOREX_URL or "https://open.er-api.com/v6/latest/USD", function(body)
        local ok_d, d = pcall(json.decode, body)
        if ok_d and d and d.rates and d.rates.MXN then
            local usd_mxn = d.rates.MXN
            fetchers.data.forex_usd = string.format("[Divisas] USD: $%.2f MXN", usd_mxn)
            if d.rates.EUR then
                local eur_mxn = usd_mxn / d.rates.EUR
                fetchers.data.forex_eur = string.format("[Divisas] EUR: $%.2f MXN", eur_mxn)
            end
        else
            curl_async("https://api.frankfurter.app/latest?from=USD&to=MXN", function(fb)
                local ok_f, fd = pcall(json.decode, fb)
                if ok_f and fd and fd.rates and fd.rates.MXN then
                    fetchers.data.forex_usd = string.format("[Divisas] USD: $%.2f MXN", fd.rates.MXN)
                end
            end)
        end
        if fetchers.on_update then fetchers.on_update() end
    end)
    return true
end

local function update_system_stats()
    local f = io.open("/proc/meminfo", "r")
    if f then
        local mem = f:read("*a")
        f:close()
        local total = tonumber(mem:match("MemTotal:%s*(%d+)"))
        local avail = tonumber(mem:match("MemAvailable:%s*(%d+)"))
        if total and avail then
            local free_gb = avail / 1048576
            local used_pct = ((total - avail) / total) * 100
            fetchers.data.system_ram = string.format("[RAM Sistema] %.1f GB libres (%.0f%% en uso)", free_gb, used_pct)
        end
    end

    local lf = io.open("/proc/loadavg", "r")
    if lf then
        local load = lf:read("*a")
        lf:close()
        local l1 = load:match("^(%S+)")
        if l1 then
            fetchers.data.system_cpu = string.format("[CPU] Carga media %s", l1)
        end
    end
end

function fetchers.update_all_internet()
    update_forex()
    update_crypto()
    update_weather()
    update_system_stats()
    collectgarbage("step", 100)
    return true
end

function fetchers.get_random_fact()
    if config.skills and config.skills.data_bubbles == false then
        return nil
    end

    update_system_stats()

    local candidates = {}
    local function add(cat, text)
        if text and #text > 0 and cat ~= last_category then
            candidates[#candidates + 1] = { cat = cat, text = text }
        end
    end

    add("forex_usd", fetchers.data.forex_usd)
    add("forex_eur", fetchers.data.forex_eur)
    add("crypto_btc", fetchers.data.crypto_btc)
    add("crypto_eth", fetchers.data.crypto_eth)
    add("crypto_sol", fetchers.data.crypto_sol)
    add("weather", fetchers.data.weather)

    if mpris.track.status == "Playing" and #mpris.track.title > 0 then
        local src_tag = (mpris.track.source == "spotify") and "[Spotify]" or "[YT Music]"
        local song_text = src_tag .. " " .. mpris.track.title
        if #mpris.track.artist > 0 then
            song_text = song_text .. " - " .. mpris.track.artist
        end
        add("music", song_text)
    end

    add("system_ram", fetchers.data.system_ram)
    add("system_cpu", fetchers.data.system_cpu)

    local tip_entry = tech_tips[math.random(1, #tech_tips)]
    local random_tip = type(tip_entry) == "function" and tip_entry() or tip_entry
    add("tech_tip", random_tip)
    add("greeting", fetchers.data.greeting)

    if #candidates == 0 then
        if fetchers.data.forex_usd then return fetchers.data.forex_usd end
        if fetchers.data.crypto_btc then return fetchers.data.crypto_btc end
        if fetchers.data.weather then return fetchers.data.weather end
        return fetchers.data.clock or "[Qwen Widget] En linea"
    end

    local pick = candidates[math.random(1, #candidates)]
    last_category = pick.cat
    return pick.text
end

function fetchers.start()
    math.randomseed(os.time())
    update_clock()
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.CLOCK_INTERVAL or 1000, update_clock)

    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 100, function()
        update_system_stats()
        update_forex()
        update_crypto()
        update_weather()
        return false
    end)

    local internet_interval = config.DATA_FETCH_INTERVAL or 300000
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, internet_interval, fetchers.update_all_internet)
end

return fetchers
