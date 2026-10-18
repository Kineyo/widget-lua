----------------------------------------------------------------------
-- lib/skills/base.lua  –  Utilidades asíncronas con timeout y reintentos
--                         para ejecución de habilidades OpenClaw
----------------------------------------------------------------------
local lgi  = require("lgi")
local Gio  = lgi.Gio
local GLib = lgi.GLib
local json = require("json")

local base = {}

function base.exec_command(cmd_str, callback, max_lines, timeout_sec)
    local t_sec = tonumber(timeout_sec) or 15
    local ok, sub = pcall(Gio.Subprocess.new,
        { "timeout", tostring(t_sec), "bash", "-c", cmd_str },
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_PIPE)
    if not ok or not sub then
        if callback then callback(false, "No se pudo iniciar el subproceso") end
        return
    end

    sub:communicate_utf8_async(nil, nil, function(s, res)
        local ok_fin, stdout, stderr = pcall(function() return s:communicate_utf8_finish(res) end)
        local out = (ok_fin and stdout and #stdout > 0) and stdout or (stderr or "")

        if max_lines and #out > 0 then
            local lines = {}
            local count = 0
            for line in out:gmatch("([^\r\n]*)[\r\n]?") do
                if #line > 0 then
                    count = count + 1
                    if count <= max_lines then
                        lines[#lines + 1] = line
                    else
                        lines[#lines + 1] = string.format("... (+%d lineas adicionales)", count - max_lines)
                        break
                    end
                end
            end
            out = table.concat(lines, "\n")
            lines = nil
        end

        if callback then
            callback(ok_fin, out)
        end
        collectgarbage("step", 50)
    end)
end

-- Async JSON HTTP/IPC request with timeout and automatic retry
function base.http_json_request(url, method, payload_tbl, timeout_sec, retries, callback)
    local max_retries = tonumber(retries) or 2
    local t_sec = tonumber(timeout_sec) or 5
    local attempt = 0

    local function try_once()
        attempt = attempt + 1
        local argv = {
            "curl", "-s", "-S", "--max-time", tostring(t_sec),
            "-X", method or "GET",
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json",
        }
        if payload_tbl then
            local ok_e, body = pcall(json.encode, payload_tbl)
            if ok_e and body then
                table.insert(argv, "-d")
                table.insert(argv, body)
            end
        end
        table.insert(argv, url)

        local ok, sub = pcall(Gio.Subprocess.new, argv,
            Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_PIPE)
        if not ok or not sub then
            if callback then callback(false, nil, "Fallo al crear cliente IPC/HTTP") end
            return
        end

        sub:communicate_utf8_async(nil, nil, function(p, res)
            local ok_c, stdout, stderr = pcall(function() return p:communicate_utf8_finish(res) end)
            local exit_ok = pcall(function() return p:get_successful() end) and p:get_successful()
            if exit_ok and ok_c and stdout and #stdout > 0 then
                local ok_j, decoded = pcall(json.decode, stdout)
                if ok_j and decoded then
                    if callback then callback(true, decoded, nil) end
                else
                    if callback then callback(true, { raw = stdout }, nil) end
                end
                return
            end

            if attempt <= max_retries then
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 350 * attempt, function()
                    try_once()
                    return false
                end)
            else
                if callback then
                    callback(false, nil, (stderr and #stderr > 0) and stderr or "Timeout o conexion rechazada")
                end
            end
        end)
    end

    try_once()
end

function base.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

return base
