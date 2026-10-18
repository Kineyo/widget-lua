----------------------------------------------------------------------
-- lib/skills/system_info.lua  –  Habilidad de Diagnostico del Sistema
--                                Incluye telemetria de RAM del widget
----------------------------------------------------------------------
local base = require("skills.base")
local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local skill = {
    name = "system_info",
    description = "Obtiene informacion en tiempo real de CPU, memoria RAM, disco, uptime y presupuesto de RAM del widget.",
    params = {},
}

function skill.run(args, callback)
    local ram_str = "N/A"
    local mem = base.read_file("/proc/meminfo")
    if mem then
        local total = tonumber(mem:match("MemTotal:%s*(%d+)"))
        local avail = tonumber(mem:match("MemAvailable:%s*(%d+)"))
        if total and avail then
            local used = total - avail
            local pct = (used / total) * 100
            ram_str = string.format("%.1f / %.1f GB (%.1f%% en uso)", used / 1048576, total / 1048576, pct)
        end
    end

    local widget_mem_str = "N/A"
    if qwen_native and qwen_native.get_memory_stats then
        local ms = qwen_native.get_memory_stats()
        if ms then
            widget_mem_str = string.format(
                "%.1f MB total (UI+Lua: %.1f MB | llama.cpp: %.1f MB) [Limite <= %.0f MB: %s]",
                ms.total_rss_mb or 0,
                ms.widget_rss_mb or 0,
                ms.llama_rss_mb or 0,
                ms.budget_mb or 500,
                ms.within_budget and "OK" or "EXCEDIDO"
            )
        end
    end

    local load_str = "N/A"
    local lavg = base.read_file("/proc/loadavg")
    if lavg then
        local l1, l5, l15 = lavg:match("^(%S+)%s+(%S+)%s+(%S+)")
        if l1 then load_str = string.format("%s (1m), %s (5m), %s (15m)", l1, l5, l15) end
    end

    local uptime_str = "N/A"
    local up = base.read_file("/proc/uptime")
    if up then
        local sec = tonumber(up:match("^(%d+)"))
        if sec then
            local h = math.floor(sec / 3600)
            local m = math.floor((sec % 3600) / 60)
            uptime_str = string.format("%d horas, %d minutos", h, m)
        end
    end

    local bat_str = nil
    local bat_cap = base.read_file("/sys/class/power_supply/BAT0/capacity") or base.read_file("/sys/class/power_supply/BAT1/capacity")
    local bat_st = base.read_file("/sys/class/power_supply/BAT0/status") or base.read_file("/sys/class/power_supply/BAT1/status")
    if bat_cap then
        bat_str = string.format("%s%% (%s)", bat_cap:gsub("%s+", ""), (bat_st or "Bateria"):gsub("%s+", ""))
    end

    base.exec_command("df -h / /home 2>/dev/null | awk 'NR>1 {print $6 \": \" $4 \" libres de \" $2}'", function(ok, disk_out)
        local lines = {
            "**[Diagnostico del Sistema - OpenClaw]**",
            string.format("- **RAM del Sistema:** %s", ram_str),
            string.format("- **RAM del Widget:** %s", widget_mem_str),
            string.format("- **Carga CPU:** %s", load_str),
            string.format("- **Tiempo activo:** %s", uptime_str),
        }
        if bat_str then
            lines[#lines + 1] = string.format("- **Bateria:** %s", bat_str)
        end
        if ok and #disk_out > 0 then
            lines[#lines + 1] = "- **Almacenamiento:**"
            for d in disk_out:gmatch("([^\r\n]+)") do
                lines[#lines + 1] = "  * " .. d
            end
        end
        local kernel = (base.read_file("/proc/sys/kernel/osrelease") or ""):gsub("%s+", "")
        lines[#lines + 1] = "- **OS:** Pop!_OS / Linux (Kernel " .. kernel .. ")"
        local res = table.concat(lines, "\n")
        lines = nil
        callback(true, res)
        collectgarbage("step", 50)
    end)
end

return skill
