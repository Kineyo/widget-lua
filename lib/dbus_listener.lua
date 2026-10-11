----------------------------------------------------------------------
-- dbus_listener.lua  –  Session-bus listener for notifications
--                       (KDE Connect and generic freedesktop)
----------------------------------------------------------------------
local lgi  = require("lgi")
local Gio  = lgi.Gio
local GLib = lgi.GLib

local config = require("config")

local dbus = {}

-- State visible to widget
dbus.notification = nil     -- { summary = "", body = "", app = "", ts = 0 }
dbus.has_badge    = false
dbus.on_notify    = nil     -- callback set by widget

----------------------------------------------------------------------
-- Clear the badge after NOTIF_TIMEOUT_MS
----------------------------------------------------------------------
local function schedule_badge_clear()
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.NOTIF_TIMEOUT_MS, function()
        dbus.has_badge = false
        dbus.notification = nil
        if dbus.on_notify then dbus.on_notify() end
        return false
    end)
end

----------------------------------------------------------------------
-- Handle an incoming notification (from any source)
----------------------------------------------------------------------
local function handle_notification(app_name, summary, body)
    dbus.notification = {
        app     = app_name or "",
        summary = summary or "",
        body    = body or "",
        ts      = os.time(),
    }
    dbus.has_badge = true
    if dbus.on_notify then dbus.on_notify() end
    schedule_badge_clear()
end

----------------------------------------------------------------------
-- Start the listener
----------------------------------------------------------------------
function dbus.start()
    local bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    if not bus then
        io.stderr:write("[qwen-widget] WARN: cannot connect to session bus\n")
        return
    end

    ---------------------------------------------------------------
    -- 1) Monitor org.freedesktop.Notifications  Notify method calls
    --    Uses AddMatch with eavesdrop (requires permissive bus policy
    --    on many desktops; if it fails we silently continue).
    ---------------------------------------------------------------
    pcall(function()
        bus:call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
            GLib.Variant("(s)", {
                "type='method_call',interface='org.freedesktop.Notifications',member='Notify',eavesdrop=true"
            }),
            nil,
            Gio.DBusCallFlags.NONE,
            -1, nil)
    end)

    -- Listen for signals matching the Notify pattern
    bus:signal_subscribe(
        nil,                                -- any sender
        "org.freedesktop.Notifications",    -- interface
        nil,                                -- any member (will filter below)
        "/org/freedesktop/Notifications",   -- path
        nil,                                -- arg0
        Gio.DBusSignalFlags.NONE,
        function(_, sender, path, iface, signal, params)
            -- The Notify signal (or method-call if eavesdropping works) has:
            -- (s app_name, u replaces_id, s icon, s summary, s body, ...)
            local ok, values = pcall(function()
                local v = params
                if v == nil then return nil end
                -- Try to unpack first 5 args
                local n = v.n_children and v:n_children() or 0
                if n >= 5 then
                    local app  = v:get_child_value(0):get_string()
                    local sum  = v:get_child_value(3):get_string()
                    local body = v:get_child_value(4):get_string()
                    return { app = app, summary = sum, body = body }
                end
                return nil
            end)
            if ok and values then
                handle_notification(values.app, values.summary, values.body)
            end
        end)

    ---------------------------------------------------------------
    -- 2) KDE Connect: subscribe to all signals from that service
    ---------------------------------------------------------------
    bus:signal_subscribe(
        config.KDECONNECT_BUS,
        nil,  -- any interface
        nil,  -- any signal
        nil,  -- any path
        nil,
        Gio.DBusSignalFlags.NONE,
        function(_, sender, path, iface, signal, params)
            -- Many KDE Connect signals; we care about notification-related ones
            if signal and (signal:lower():find("notification") or
                           signal:lower():find("notif")) then
                local body_text = ""
                pcall(function()
                    if params and params:n_children() > 0 then
                        body_text = params:get_child_value(0):get_string()
                    end
                end)
                handle_notification("KDE Connect", signal, body_text)
            end
        end)

    ---------------------------------------------------------------
    -- 3) Fallback: listen for ActionInvoked / NotificationClosed
    --    (these are standard signals, always work)
    ---------------------------------------------------------------
    bus:signal_subscribe(
        nil,
        "org.freedesktop.Notifications",
        "ActionInvoked",
        "/org/freedesktop/Notifications",
        nil,
        Gio.DBusSignalFlags.NONE,
        function() end)  -- just ensures the bus stays active
end

return dbus
