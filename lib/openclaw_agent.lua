----------------------------------------------------------------------
-- openclaw_agent.lua  –  OpenClaw Agent Capabilities & Skills Engine
--                        Inspired by https://github.com/openclaw/openclaw
--                        "The AI that really does things. Any OS. Any Platform. 🦞"
----------------------------------------------------------------------
local lgi       = require("lgi")
local Gio       = lgi.Gio
local GLib      = lgi.GLib

local config    = require("config")
local json      = require("json")
local mpris     = require("mpris")

local agent = {}

agent.enabled       = true
agent.gateway_alive = false

----------------------------------------------------------------------
-- Async subprocess helper
----------------------------------------------------------------------
local function exec_command(cmd_str, callback, max_lines)
    local ok, sub = pcall(Gio.Subprocess.new,
        { "bash", "-c", cmd_str },
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_PIPE)
    if not ok or not sub then
        if callback then callback(false, "No se pudo ejecutar el proceso") end
        return
    end

    sub:communicate_utf8_async(nil, nil, function(s, res)
        local ok_fin, stdout, stderr = pcall(function() return s:communicate_utf8_finish(res) end)
        local out = (ok_fin and stdout and #stdout > 0) and stdout or (stderr or "")

        -- Limit output length if requested
        if max_lines and #out > 0 then
            local lines = {}
            local count = 0
            for line in out:gmatch("([^\r\n]*)[\r\n]?") do
                if #line > 0 then
                    count = count + 1
                    if count <= max_lines then
                        lines[#lines+1] = line
                    else
                        lines[#lines+1] = string.format("... (+%d líneas más)", count - max_lines)
                        break
                    end
                end
            end
            out = table.concat(lines, "\n")
        end

        if callback then
            callback(ok_fin, out)
        end
    end)
end

----------------------------------------------------------------------
-- Read system file helper
----------------------------------------------------------------------
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

----------------------------------------------------------------------
-- OpenClaw Skills Catalog
----------------------------------------------------------------------
agent.skills = {}

-- 1. System Info Skill
agent.skills["system_info"] = {
    name = "system_info",
    description = "Obtiene información en tiempo real de CPU, memoria RAM, disco, uptime y batería.",
    params = {},
    run = function(args, callback)
        -- RAM from /proc/meminfo
        local ram_str = "N/A"
        local mem = read_file("/proc/meminfo")
        if mem then
            local total = tonumber(mem:match("MemTotal:%s*(%d+)"))
            local avail = tonumber(mem:match("MemAvailable:%s*(%d+)"))
            if total and avail then
                local used = total - avail
                local pct = (used / total) * 100
                ram_str = string.format("%.1f / %.1f GB (%.1f%% en uso)", used / 1048576, total / 1048576, pct)
            end
        end

        -- CPU Load from /proc/loadavg
        local load_str = "N/A"
        local lavg = read_file("/proc/loadavg")
        if lavg then
            local l1, l5, l15 = lavg:match("^(%S+)%s+(%S+)%s+(%S+)")
            if l1 then load_str = string.format("%s (1m), %s (5m), %s (15m)", l1, l5, l15) end
        end

        -- Uptime from /proc/uptime
        local uptime_str = "N/A"
        local up = read_file("/proc/uptime")
        if up then
            local sec = tonumber(up:match("^(%d+)"))
            if sec then
                local h = math.floor(sec / 3600)
                local m = math.floor((sec % 3600) / 60)
                uptime_str = string.format("%d horas, %d minutos", h, m)
            end
        end

        -- Battery
        local bat_str = nil
        local bat_cap = read_file("/sys/class/power_supply/BAT0/capacity") or read_file("/sys/class/power_supply/BAT1/capacity")
        local bat_st = read_file("/sys/class/power_supply/BAT0/status") or read_file("/sys/class/power_supply/BAT1/status")
        if bat_cap then
            bat_str = string.format("%s%% (%s)", bat_cap:gsub("%s+", ""), (bat_st or "Batería"):gsub("%s+", ""))
        end

        -- Disk space using df
        exec_command("df -h / /home 2>/dev/null | awk 'NR>1 {print $6 \": \" $4 \" libres de \" $2}'", function(ok, disk_out)
            local lines = {
                "📊 **Diagnóstico del Sistema (OpenClaw):**",
                string.format("• **RAM:** %s", ram_str),
                string.format("• **Carga CPU:** %s", load_str),
                string.format("• **Tiempo encendido:** %s", uptime_str),
            }
            if bat_str then
                lines[#lines+1] = string.format("• **Batería:** %s", bat_str)
            end
            if ok and #disk_out > 0 then
                lines[#lines+1] = "• **Almacenamiento:**"
                for d in disk_out:gmatch("([^\r\n]+)") do
                    lines[#lines+1] = "   ▫ " .. d
                end
            end
            lines[#lines+1] = "• **OS:** Pop!_OS 24.04 LTS (Kernel " .. (read_file("/proc/sys/kernel/osrelease") or ""):gsub("%s+", "") .. ")"
            callback(true, table.concat(lines, "\n"))
        end)
    end
}

-- 2. Bash / Terminal Execution Skill
agent.skills["bash"] = {
    name = "bash",
    description = "Ejecuta comandos de shell en el sistema Pop!_OS local y retorna la salida.",
    params = { command = "string (comando a ejecutar)" },
    run = function(args, callback)
        local cmd = type(args) == "table" and (args.command or args.cmd) or tostring(args)
        if not cmd or #cmd == 0 then
            callback(false, "Comando vacío")
            return
        end

        exec_command(cmd, function(ok, out)
            local res = string.format("💻 **Shell [`%s`]:**\n```bash\n%s\n```", cmd, #out > 0 and out or "(Comando completado sin salida)")
            callback(ok, res)
        end, 40)
    end
}

-- 3. Media Player Control Skill (YouTube Music / MPRIS)
agent.skills["media_control"] = {
    name = "media_control",
    description = "Controla YouTube Music y reproductores de música (play, pause, next, prev, seek, status).",
    params = { action = "play|pause|play_pause|next|prev|status|seek", value = "número opcional para seek" },
    run = function(args, callback)
        local act = "status"
        local val = nil
        if type(args) == "table" then
            act = args.action or args.act or "status"
            val = tonumber(args.value or args.val or args.position)
        elseif type(args) == "string" then
            act = args
        end

        if act == "next" then
            mpris.next()
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 400, function()
                mpris.refresh()
                callback(true, "⏭ Canción siguiente: **" .. (mpris.track.title or "") .. "**")
                return false
            end)
        elseif act == "prev" or act == "previous" then
            mpris.previous()
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 400, function()
                mpris.refresh()
                callback(true, "⏮ Canción anterior: **" .. (mpris.track.title or "") .. "**")
                return false
            end)
        elseif act == "play" or act == "pause" or act == "play_pause" or act == "toggle" then
            mpris.play_pause()
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, function()
                mpris.refresh()
                callback(true, string.format("⏯ Reproductor: %s (**%s**)", mpris.track.status, mpris.track.title or "N/A"))
                return false
            end)
        elseif act == "seek" and val then
            mpris.seek(val)
            callback(true, string.format("⏩ Posición cambiada a %s", mpris.format_time(val)))
        else
            -- Status
            mpris.refresh()
            local t = mpris.track
            if #t.title > 0 then
                local res = string.format("🎵 **YouTube Music:**\n• **Título:** %s\n• **Artista:** %s\n• **Estado:** %s\n• **Tiempo:** %s / %s",
                    t.title, #t.artist > 0 and t.artist or "Desconocido", t.status,
                    mpris.format_time(t.position), mpris.format_time(t.length))
                callback(true, res)
            else
                callback(true, "🎵 No hay ninguna canción reproduciéndose actualmente.")
            end
        end
    end
}

-- 4. Web Search Skill
agent.skills["web_search"] = {
    name = "web_search",
    description = "Busca información rápida en la web mediante DuckDuckGo Instant Answers.",
    params = { query = "string de búsqueda" },
    run = function(args, callback)
        local q = type(args) == "table" and (args.query or args.q) or tostring(args)
        if not q or #q == 0 then
            callback(false, "Búsqueda vacía")
            return
        end

        local encoded = q:gsub("[^%w _~%.%-]", function(c)
            return string.format("%%%02X", string.byte(c))
        end):gsub(" ", "+")

        local url = "https://api.duckduckgo.com/?q=" .. encoded .. "&format=json&no_html=1&skip_disambig=1"
        exec_command(string.format("curl -s -m 8 '%s'", url), function(ok, body)
            if ok and body and #body > 0 then
                local d = json.decode(body)
                if d then
                    local answer = d.Answer and #d.Answer > 0 and d.Answer or nil
                    local abstract = d.AbstractText and #d.AbstractText > 0 and d.AbstractText or nil
                    local source_url = d.AbstractURL or nil

                    if answer or abstract then
                        local out = string.format("🔍 **Búsqueda OpenClaw:** *%s*\n%s\n%s",
                            q, answer or abstract, source_url and ("🔗 " .. source_url) or "")
                        callback(true, out)
                        return
                    end
                end
            end

            -- Fallback: Quick DuckDuckGo HTML snippet search
            local fallback_url = "https://html.duckduckgo.com/html/?q=" .. encoded
            exec_command(string.format("curl -s -m 8 -A 'Mozilla/5.0' '%s' | grep -o -E '<a class=\"result__snippet[^\"]*\">[^<]*' | head -n 3 | sed -e 's/<[^>]*>//g'", fallback_url), function(f_ok, f_out)
                if f_ok and f_out and #f_out > 0 then
                    callback(true, string.format("🔍 **Resultados para:** *%s*\n%s", q, f_out))
                else
                    callback(true, string.format("🔍 No se encontraron respuestas inmediatas para: *%s*", q))
                end
            end)
        end)
    end
}

-- 5. Launch Application Skill
agent.skills["app_launch"] = {
    name = "app_launch",
    description = "Lanza aplicaciones de escritorio (navegador, terminal, youtube music, archivos, calculadora, etc.).",
    params = { app = "nombre de la aplicación (ej: google-chrome, firefox, youtube-music, cosmic-term, nautilus)" },
    run = function(args, callback)
        local app = type(args) == "table" and (args.app or args.name) or tostring(args)
        if not app or #app == 0 then
            callback(false, "Aplicación no especificada")
            return
        end

        local app_map = {
            ["musica"] = "youtube-music-desktop-app || youtube-music",
            ["youtube music"] = "youtube-music-desktop-app || youtube-music",
            ["navegador"] = "xdg-open 'https://music.youtube.com' &",
            ["terminal"] = "cosmic-term || gnome-terminal || xterm &",
            ["archivos"] = "nautilus || cosmic-files &",
            ["calculadora"] = "gnome-calculator || calc &",
            ["editor"] = "gedit || code || nano &",
        }

        local cmd = app_map[app:lower()] or (app .. " &")
        exec_command(cmd, function(ok, _)
            callback(true, string.format("🚀 Lanzando aplicación: **%s**", app))
        end)
    end
}

-- 6. Screenshot Skill
agent.skills["screenshot"] = {
    name = "screenshot",
    description = "Toma una captura de pantalla del escritorio y la guarda en Pictures/Capturas o /tmp.",
    params = {},
    run = function(args, callback)
        local path = os.getenv("HOME") .. "/Imágenes/Capturas/captura_" .. os.date("%Y%m%d_%H%M%S") .. ".png"
        local cmd = string.format("mkdir -p $(dirname '%s') && (grim '%s' 2>/dev/null || maim '%s' 2>/dev/null || gnome-screenshot -f '%s' 2>/dev/null || import -window root '%s' 2>/dev/null)",
            path, path, path, path, path)
        exec_command(cmd, function(ok, _)
            if ok then
                callback(true, string.format("📸 Captura de pantalla guardada en:\n`%s`", path))
            else
                callback(false, "No se pudo tomar la captura (instala grim o maim o gnome-screenshot).")
            end
        end)
    end
}

-- 7. Desktop Notification Skill
agent.skills["notify"] = {
    name = "notify",
    description = "Envía una notificación emergente al escritorio.",
    params = { title = "título", message = "mensaje" },
    run = function(args, callback)
        local title = "OpenClaw Qwen"
        local msg = "Alerta del agente"
        if type(args) == "table" then
            title = args.title or title
            msg = args.message or args.msg or msg
        elseif type(args) == "string" then
            msg = args
        end

        exec_command(string.format("notify-send '%s' '%s' -i dialog-information", title:gsub("'", ""), msg:gsub("'", "")), function(ok, _)
            callback(true, string.format("🔔 Notificación enviada: **%s**", title))
        end)
    end
}

-- 8. OpenClaw Gateway Status Skill
agent.skills["openclaw_gateway"] = {
    name = "openclaw_gateway",
    description = "Verifica el estado del Gateway local de OpenClaw y canales conectados.",
    params = {},
    run = function(args, callback)
        exec_command("openclaw gateway status 2>/dev/null || curl -s -m 2 http://127.0.0.1:18789/health || echo 'OFFLINE'", function(ok, out)
            if out and not out:find("OFFLINE") then
                agent.gateway_alive = true
                callback(true, "🦞 **OpenClaw Gateway:** En línea y conectado.\n" .. out)
            else
                agent.gateway_alive = false
                callback(true, "🦞 **OpenClaw Engine:** Operando en modo nativo integrado (Lua + DBus + MPRIS). Gateway externo inactivo.")
            end
        end)
    end
}

----------------------------------------------------------------------
-- Execute a registered skill
----------------------------------------------------------------------
function agent.execute(skill_name, args, callback)
    local s = agent.skills[skill_name]
    if not s then
        if callback then callback(false, "Habilidad no encontrada: " .. tostring(skill_name)) end
        return
    end

    s.run(args, function(ok, res)
        if callback then callback(ok, res) end
    end)
end

----------------------------------------------------------------------
-- Handle Slash Commands
----------------------------------------------------------------------
function agent.handle_slash_command(text, callback)
    if not text:find("^/") then return false end

    local cmd, arg_str = text:match("^/(%S+)%s*(.*)$")
    if not cmd then return false end
    cmd = cmd:lower()

    if cmd == "help" or cmd == "ayuda" then
        local help_text = table.concat({
            "🦞 **OpenClaw Agent — Comandos Rápidos:**",
            "• `/sys` o `/status` — Diagnóstico de CPU, RAM, disco y batería",
            "• `/music` o `/player` — Abre o despliega el reproductor de YouTube Music",
            "• `/next`, `/prev`, `/play`, `/pause` — Controles directos de música",
            "• `/sh <comando>` — Ejecuta un comando en la terminal",
            "• `/search <consulta>` — Búsqueda rápida en la web",
            "• `/app <nombre>` — Lanza una aplicación (chrome, terminal, etc.)",
            "• `/shot` o `/screenshot` — Toma una captura de pantalla",
            "• `/skills` — Muestra el catálogo de habilidades de OpenClaw",
            "• `/clear` — Limpia el historial del chat",
            "• `/model <nombre>` — Cambia el modelo de Ollama",
            "• `/gateway` — Verifica el Gateway de OpenClaw",
        }, "\n")
        callback(help_text)
        return true

    elseif cmd == "skills" or cmd == "habilidades" then
        local list = { "🦞 **Catálogo de Habilidades OpenClaw Registradas:**" }
        for name, sk in pairs(agent.skills) do
            list[#list+1] = string.format("⚡ **%s**: %s", name, sk.description)
        end
        callback(table.concat(list, "\n"))
        return true

    elseif cmd == "sys" or cmd == "status" then
        agent.execute("system_info", {}, function(ok, res)
            callback(res)
        end)
        return true

    elseif cmd == "music" or cmd == "player" or cmd == "reproductor" then
        agent.execute("media_control", { action = "status" }, function(ok, res)
            callback(res)
        end)
        return true

    elseif cmd == "bubble" or cmd == "burbuja" or cmd == "info" then
        local ok_f, fetchers = pcall(require, "fetchers")
        local fact = ok_f and fetchers.get_random_fact() or "💡 Información de sistema activa"
        callback(fact)
        return true

    elseif cmd == "next" or cmd == "siguiente" then
        agent.execute("media_control", { action = "next" }, function(ok, res)
            callback(res)
        end)
        return true

    elseif cmd == "prev" or cmd == "anterior" then
        agent.execute("media_control", { action = "prev" }, function(ok, res)
            callback(res)
        end)
        return true

    elseif cmd == "play" or cmd == "pause" or cmd == "toggle" then
        agent.execute("media_control", { action = "play_pause" }, function(ok, res)
            callback(res)
        end)
        return true

    elseif cmd == "sh" or cmd == "bash" or cmd == "exec" then
        if #arg_str == 0 then
            callback("⚠ Uso: `/sh <comando bash>` (ej: `/sh free -h`)")
        else
            agent.execute("bash", { command = arg_str }, function(ok, res)
                callback(res)
            end)
        end
        return true

    elseif cmd == "search" or cmd == "buscar" then
        if #arg_str == 0 then
            callback("⚠ Uso: `/search <término>`")
        else
            agent.execute("web_search", { query = arg_str }, function(ok, res)
                callback(res)
            end)
        end
        return true

    elseif cmd == "app" or cmd == "abrir" then
        if #arg_str == 0 then
            callback("⚠ Uso: `/app <nombre>` (ej: `/app terminal` o `/app youtube music`)")
        else
            agent.execute("app_launch", { app = arg_str }, function(ok, res)
                callback(res)
            end)
        end
        return true

    elseif cmd == "shot" or cmd == "screenshot" or cmd == "captura" then
        agent.execute("screenshot", {}, function(ok, res)
            callback(res)
        end)
        return true

    elseif cmd == "gateway" or cmd == "openclaw" then
        agent.execute("openclaw_gateway", {}, function(ok, res)
            callback(res)
        end)
        return true

    elseif cmd == "model" or cmd == "modelo" then
        if #arg_str > 0 then
            config.OLLAMA_MODEL = arg_str
            callback("✓ Modelo cambiado a: **" .. config.OLLAMA_MODEL .. "**")
        else
            callback("Modelo actual: **" .. config.OLLAMA_MODEL .. "**\nUso: `/model <nombre>` (ej: `/model qwen3:0.6b` o `/model qwen3:4b`)")
        end
        return true
    end

    return false
end

----------------------------------------------------------------------
-- Tool invocation detection in LLM output
----------------------------------------------------------------------
function agent.detect_tool_call(text)
    if not text then return nil end

    -- Pattern 1: ```tool:name {...} ``` or ```tool ... ```
    local tool_name, json_body = text:match("```tool:(%w+)%s*(%b{})%s*```")
    if not tool_name then
        tool_name, json_body = text:match("```tool%s*(%b{})%s*```")
    end

    if json_body then
        local d = json.decode(json_body)
        if d then
            local name = tool_name or d.tool or d.name
            local args = d.args or d.params or d
            return name, args
        end
    end

    -- Pattern 2: Raw JSON {"tool": "...", "args": {...}}
    local raw_json = text:match("(%{%s*\"tool\"%s*:%s*\"[^\"]+\"%s*,.-%})")
    if raw_json then
        local d = json.decode(raw_json)
        if d and d.tool then
            return d.tool, d.args or d
        end
    end

    return nil
end

----------------------------------------------------------------------
-- System Prompt with OpenClaw Persona and Skill schema
----------------------------------------------------------------------
function agent.get_system_prompt()
    return [[Eres OpenClaw-Qwen, un agente de IA autónomo ultraligero que opera localmente en Pop!_OS 24.04 LTS (inspirado en OpenClaw, "The AI that really does things" 🦞).
Tienes habilidades reales sobre el sistema y el escritorio:
1. media_control: controlar YouTube Music (play, pause, next, prev, status)
2. system_info: diagnosticar CPU, RAM, almacenamiento y batería
3. bash: ejecutar comandos en la terminal
4. web_search: buscar información rápida en la web
5. app_launch: abrir aplicaciones
6. screenshot: tomar capturas de pantalla

Si el usuario te pide una acción en el sistema o música, invoca la herramienta usando este bloque exacto:
```tool:nombre_habilidad
{"parametro": "valor"}
```
Por ejemplo:
- Para cambiar canción: ```tool:media_control {"action": "next"}```
- Para pausar: ```tool:media_control {"action": "pause"}```
- Para ver qué suena: ```tool:media_control {"action": "status"}```
- Para revisar recursos: ```tool:system_info {}```
- Para comandos: ```tool:bash {"command": "free -h"}```

Si el usuario solo conversa o hace preguntas teóricas, responde de forma concisa, amigable y directa en español sin invocar herramientas innecesarias.]]
end

return agent
