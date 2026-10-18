----------------------------------------------------------------------
-- widget.lua  –  Main Floating Bubble with State Machine Sprites,
--                Real-Time Docked Panel Tracking (Player, Chat, Lyrics,
--                Bubbles), and Strict <= 500 MB RAM Controller.
--                Zero emojis anywhere.
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gtk    = lgi.require("Gtk", "3.0")
local Gdk    = lgi.require("Gdk", "3.0")
local GLib   = lgi.GLib
local cairo  = lgi.cairo

local config        = require("config")
local utils         = require("utils")
local icons         = require("icons")
local animator      = require("animator")
local fetchers      = require("fetchers")
local dbus_l        = require("dbus_listener")
local chat          = require("chat")
local bubbles       = require("bubbles")
local launcher      = require("launcher")
local mpris         = require("mpris")
local player        = require("player")
local lyrics        = require("lyrics")
local lyrics_bubble = require("lyrics_bubble")
local text_popup    = require("text_popup")
local model_mgr     = require("model_manager")

local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local widget = {}
widget.window = nil
widget.state  = "idle" -- "idle" | "hover" | "chatting" | "thinking" | "music" | "grammar" | "error"

local sprites     = {}
local wx, wy      = 0, 0
local dragging    = false
local is_hovered  = false
local drag_ox, drag_oy = 0, 0
local was_drag    = false
local snap_edge   = "right"
local active_override_state = nil

local function screen_size()
    return utils.screen_size()
end

-- Preload / resolve sprite for current state
local function get_current_sprite()
    local st = widget.state or "idle"
    local s = config.BUBBLE_SIZE or 72
    if not sprites[st] then
        sprites[st] = utils.load_sprite(st, s)
    end
    return sprites[st] or sprites["idle"]
end

local function refresh_effective_state()
    if active_override_state and active_override_state ~= "idle" then
        widget.state = active_override_state
    elseif is_hovered then
        widget.state = "hover"
    elseif chat.visible then
        widget.state = "chatting"
    elseif mpris.track.status == "Playing" then
        widget.state = "music"
    else
        widget.state = "idle"
    end
    if widget.window then
        widget.window:queue_draw()
    end
end

function widget.set_state(new_state)
    if new_state == "idle" then
        active_override_state = nil
    else
        active_override_state = new_state
    end
    refresh_effective_state()
end

-- Update all docked windows dynamically in real time when bubble moves
local function reposition_all_docked(edge_hint)
    local bsize = config.BUBBLE_SIZE or 72
    local edge = edge_hint or snap_edge
    lyrics_bubble.reposition(wx, wy, bsize, edge)
    player.reposition(wx, wy, bsize, edge)
    chat.reposition(wx, wy, bsize, edge)
    bubbles.reposition(wx, wy, bsize)
    if launcher.reposition then
        launcher.reposition()
    end
end

local function snap_to_edge(win, from_x, from_y)
    local sw, sh = screen_size()
    local s = config.BUBBLE_SIZE or 72
    local m = config.BUBBLE_MARGIN or 8

    local d_left   = from_x
    local d_right  = sw - (from_x + s)
    local d_top    = from_y
    local d_bottom = sh - (from_y + s)

    local min_d = math.min(d_left, d_right, d_top, d_bottom)
    local tx, ty = from_x, from_y

    if min_d == d_left then
        tx = m
        snap_edge = "left"
    elseif min_d == d_right then
        tx = sw - s - m
        snap_edge = "right"
    elseif min_d == d_top then
        ty = m
        snap_edge = "top"
    else
        ty = sh - s - m - 48
        snap_edge = "bottom"
    end

    tx, ty = utils.clamp_to_screen(tx, ty, s, s, m)

    local start_x, start_y = from_x, from_y
    local anim = animator.new({
        duration = config.SNAP_DURATION_MS or 220,
        ease = utils.ease_out,
        on_update = function(t)
            local cx = utils.lerp(start_x, tx, t)
            local cy = utils.lerp(start_y, ty, t)
            wx, wy = math.floor(cx), math.floor(cy)
            win:move(wx, wy)
            reposition_all_docked(snap_edge)
        end,
    })
    anim.value = 0
    anim.forward = true
    anim:start()
end

local function show_next_data()
    if config.skills and config.skills.data_bubbles == false then
        return true
    end
    local text = fetchers.get_random_fact()
    if text and #text > 0 then
        bubbles.show(text, wx, wy, config.BUBBLE_SIZE, snap_edge)
    end
    return true
end

local function on_draw(_, cr)
    local s = config.BUBBLE_SIZE or 72
    local r = s / 2

    cr:set_operator(cairo.Operator.SOURCE)
    cr:set_source_rgba(0, 0, 0, 0)
    cr:paint()
    cr:set_operator(cairo.Operator.OVER)

    local is_playing = (mpris.track.status == "Playing")
    local st = widget.state or "idle"

    -- 1. Soft ambient drop shadow
    cr:save()
    for k = 3, 1, -1 do
        cr:arc(r, r + 2 + k * 0.7, r - 3, 0, 2 * math.pi)
        cr:set_source_rgba(0, 0, 0, 0.05 * (4 - k))
        cr:fill()
    end
    cr:restore()

    -- 2. State-aware radial glow
    if is_hovered or is_playing or st ~= "idle" then
        cr:save()
        cr:arc(r, r, r, 0, 2 * math.pi)
        local glow = cairo.Pattern.create_radial(r, r, r - 6, r, r, r)
        local gc = config.ACCENT
        if st == "music" or is_playing then
            gc = config.ACCENT_PINK
        elseif st == "grammar" then
            gc = { 0.20, 0.83, 0.60 }
        elseif st == "thinking" then
            gc = { 0.96, 0.72, 0.18 }
        elseif st == "error" then
            gc = { 0.94, 0.27, 0.27 }
        end
        glow:add_color_stop_rgba(0, gc[1], gc[2], gc[3], is_hovered and 0.48 or 0.32)
        glow:add_color_stop_rgba(1, gc[1], gc[2], gc[3], 0.0)
        cr:set_source(glow)
        cr:fill()
        cr:restore()
    end

    -- 3. Dark circle background
    local inner_r = r - (config.GLOW_WIDTH or 2)
    cr:save()
    cr:arc(r, r, inner_r, 0, 2 * math.pi)
    utils.set_colour(cr, config.BG)
    cr:fill()
    cr:restore()

    -- 4. State sprite / avatar rendered inside circular mask
    local pb = get_current_sprite()
    if pb then
        utils.draw_avatar(cr, pb, r, r, inner_r - 0.5)
    else
        cr:save()
        cr:arc(r, r, inner_r - 0.5, 0, 2 * math.pi)
        cr:set_source_rgba(config.ACCENT[1], config.ACCENT[2], config.ACCENT[3], 0.25)
        cr:fill()
        icons.draw(cr, "cpu", s, s, { 1, 1, 1, 0.9 })
        cr:restore()
    end

    -- 5. Vector Music badge (bottom-left) when playing
    if is_playing then
        local bx, by, br = 14, s - 14, 9.5
        cr:save()
        cr:arc(bx, by, br, 0, 2 * math.pi)
        cr:set_source_rgba(0.06, 0.07, 0.12, 0.96)
        cr:fill_preserve()
        cr:set_source_rgba(config.ACCENT_PINK[1], config.ACCENT_PINK[2], config.ACCENT_PINK[3], 0.90)
        cr:set_line_width(1.2)
        cr:stroke()
        cr:translate(bx - 6, by - 6)
        icons.draw(cr, "music", 12, 12, { 1, 1, 1, 1 })
        cr:restore()
    end

    -- 6. Vector Notification badge (top-right)
    if dbus_l.has_badge then
        local nx, ny, nr = s - 14, 14, 7.5
        cr:save()
        cr:arc(nx, ny, nr, 0, 2 * math.pi)
        cr:set_source_rgba(0.96, 0.62, 0.04, 0.96)
        cr:fill_preserve()
        cr:set_source_rgba(1.0, 1.0, 1.0, 0.90)
        cr:set_line_width(1.1)
        cr:stroke()
        cr:restore()
    end

    return true
end

function widget.build()
    local s = config.BUBBLE_SIZE or 72

    local win = Gtk.Window {
        type = Gtk.WindowType.POPUP,
        title = "Qwen Desktop Widget",
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = false,
        accept_focus = false,
        type_hint = Gdk.WindowTypeHint.DOCK,
        default_width  = s,
        default_height = s,
    }
    win:set_keep_above(true)
    win:set_app_paintable(true)
    win:set_size_request(s, s)
    win:set_tooltip_text("Qwen Desktop Assistant\n- Clic izquierdo: Chat IA y Configuracion\n- Clic derecho o Scroll: Burbuja de Datos\n- Clic central: Reproductor YouTube Music / Spotify")

    local screen = win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then win:set_visual(visual) end

    -- Preload all state sprites from assets/sprites/
    for _, st in ipairs({ "idle", "hover", "chatting", "thinking", "music", "grammar", "error" }) do
        sprites[st] = utils.load_sprite(st, s)
    end

    win:add_events(
        Gdk.EventMask.BUTTON_PRESS_MASK +
        Gdk.EventMask.BUTTON_RELEASE_MASK +
        Gdk.EventMask.POINTER_MOTION_MASK +
        Gdk.EventMask.ENTER_NOTIFY_MASK +
        Gdk.EventMask.LEAVE_NOTIFY_MASK +
        Gdk.EventMask.SCROLL_MASK)

    win.on_draw = on_draw

    win.on_enter_notify_event = function()
        if not dragging then
            is_hovered = true
            local gdk_win = win:get_window()
            if gdk_win then
                local display = gdk_win:get_display()
                local cursor = Gdk.Cursor.new_from_name(display, "pointer")
                gdk_win:set_cursor(cursor)
            end
            refresh_effective_state()
        end
        return false
    end

    win.on_leave_notify_event = function()
        is_hovered = false
        local gdk_win = win:get_window()
        if gdk_win then
            gdk_win:set_cursor(nil)
        end
        refresh_effective_state()
        return false
    end

    win.on_scroll_event = function()
        lyrics_bubble.hide()
        show_next_data()
        return true
    end

    win.on_button_press_event = function(_, event)
        if event.button == 1 and (event.type == 5 or event.type == Gdk.EventType["2BUTTON_PRESS"]) then
            lyrics_bubble.hide()
            show_next_data()
            return true
        end

        if event.button == 1 then
            dragging = true
            was_drag = false
            drag_ox = event.x
            drag_oy = event.y
            return true
        elseif event.button == 2 then
            if not config.skills or config.skills.player ~= false then
                player.toggle(wx, wy, config.BUBBLE_SIZE, snap_edge)
            end
            return true
        elseif event.button == 3 then
            lyrics_bubble.hide()
            show_next_data()
            return true
        end
        return false
    end

    -- Real-time coordinate update for main bubble AND all docked panels
    win.on_motion_notify_event = function(_, event)
        if dragging then
            local nx = event.x_root - drag_ox
            local ny = event.y_root - drag_oy
            if math.abs(nx - wx) > 4 or math.abs(ny - wy) > 4 then
                was_drag = true
            end
            wx, wy = utils.clamp_to_screen(math.floor(nx), math.floor(ny), s, s, 2)
            win:move(wx, wy)
            reposition_all_docked("auto")
            return true
        end
        return false
    end

    win.on_button_release_event = function(_, event)
        if event.button == 1 then
            dragging = false
            if was_drag then
                snap_to_edge(win, wx, wy)
            else
                bubbles.hide()
                lyrics_bubble.hide()
                chat.build(win)
                chat.toggle(wx, wy, config.BUBBLE_SIZE, snap_edge)
                refresh_effective_state()
            end
            return true
        end
        return false
    end

    chat.on_invoke_bubble = function()
        show_next_data()
    end
    chat.on_state_change = function(st)
        widget.set_state(st)
    end
    text_popup.on_state_change = function(st)
        widget.set_state(st)
    end
    bubbles.on_next = function()
        show_next_data()
    end

    launcher.get_orb = function()
        return wx, wy, config.BUBBLE_SIZE
    end
    launcher.is_blocked = function()
        return dragging
    end
    launcher.on_action = function(action_id)
        if action_id == "chat" then
            bubbles.hide()
            lyrics_bubble.hide()
            chat.build(win)
            chat.toggle(wx, wy, config.BUBBLE_SIZE, snap_edge)
        elseif action_id == "bubble" then
            lyrics_bubble.hide()
            show_next_data()
        elseif action_id == "music" then
            player.toggle(wx, wy, config.BUBBLE_SIZE, snap_edge)
        elseif action_id == "sys" then
            local ok_ag, openclaw = pcall(require, "openclaw_agent")
            if ok_ag and openclaw then
                openclaw.handle_slash_command("/sys", function(res)
                    GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
                        bubbles.show("[Sistema] " .. (res or ""):gsub("\n+", " | "), wx, wy, config.BUBBLE_SIZE, snap_edge, 14000)
                        return false
                    end)
                end)
            else
                show_next_data()
            end
        elseif action_id == "shot" then
            local ok_ag, openclaw = pcall(require, "openclaw_agent")
            if ok_ag and openclaw then
                openclaw.handle_slash_command("/shot", function(res)
                    GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
                        bubbles.show(res or "[Captura completada]", wx, wy, config.BUBBLE_SIZE, snap_edge, 8000)
                        return false
                    end)
                end)
            end
        elseif action_id == "quit" then
            Gtk.main_quit()
        end
    end

    fetchers.on_update = function()
        win:queue_draw()
    end

    mpris.on_status_change = function(status)
        refresh_effective_state()
        if config.LYRICS_ENABLED then
            lyrics.set_status(status)
        end
    end

    mpris.on_track_change = function(track)
        refresh_effective_state()
        if player.update_ui then player.update_ui() end
        if track and #track.title > 0 and track.status ~= "Stopped" then
            local src_tag = (track.source == "spotify") and "[Spotify]" or "[YT Music]"
            local song_text = src_tag .. " " .. track.title
            if track.artist and #track.artist > 0 and track.artist ~= "YouTube Music" then
                song_text = song_text .. " - " .. track.artist
            end
            bubbles.show(song_text, wx, wy, config.BUBBLE_SIZE, snap_edge, 12000)
        end
        if config.LYRICS_ENABLED then
            lyrics.set_track(track)
        end
    end

    lyrics.on_line_change = function(text)
        if config.LYRICS_ENABLED then
            lyrics_bubble.show_line(text, wx, wy, config.BUBBLE_SIZE, snap_edge)
        end
    end

    lyrics.on_hide = function()
        lyrics_bubble.hide()
    end

    mpris.add_track_listener(function(track)
        if config.LYRICS_ENABLED then
            lyrics.set_track(track)
        end
    end)

    mpris.add_position_listener(function(pos, len)
        if config.LYRICS_ENABLED then
            lyrics.on_position(pos, len)
        end
    end)

    mpris.add_status_listener(function(status)
        refresh_effective_state()
        if config.LYRICS_ENABLED then
            lyrics.set_status(status)
        end
    end)

    dbus_l.on_notify = function()
        if dbus_l.notification then
            local notif = dbus_l.notification
            local text = "[Notificacion] " .. (notif.summary or "")
            if notif.body and #notif.body > 0 and notif.body ~= notif.summary then
                text = text .. "\n" .. notif.body
            end
            bubbles.show(text, wx, wy, config.BUBBLE_SIZE, snap_edge)
        end
        win:queue_draw()
    end

    widget.window = win
    return win
end

function widget.start()
    local win = widget.window
    if not win then return end

    local sw, sh = screen_size()
    wx = sw - config.BUBBLE_SIZE - config.BUBBLE_MARGIN
    wy = sh - config.BUBBLE_SIZE - config.BUBBLE_MARGIN - 60
    snap_edge = "right"

    win:move(wx, wy)
    win:show_all()
    win:set_opacity(0)

    animator.fade(win, "in")

    fetchers.start()
    dbus_l.start()
    mpris.start()

    -- Verify & auto-download default GGUF models (es-grammar + qwen3.0-0.8b) on first run
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 800, function()
        local st = model_mgr.status()
        if not st.grammar.ready or not st.chat.ready then
            bubbles.show("[Instalacion IA] Descargando modelos locales por defecto (es-grammar y qwen3.0-0.8b)...", wx, wy, config.BUBBLE_SIZE, snap_edge, 10000)
            model_mgr.ensure_defaults(nil, function(ok_all)
                if ok_all then
                    bubbles.show("[Modelos Listos] es-grammar.gguf y qwen3.0-0.8b.gguf verificados.", wx, wy, config.BUBBLE_SIZE, snap_edge, 6000)
                end
            end)
        end
        return false
    end)

    if config.LYRICS_ENABLED then
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, function()
            if mpris.track and #mpris.track.title > 0 and mpris.track.status == "Playing" then
                lyrics.set_track(mpris.track)
            end
            return false
        end)
    end

    if not config.skills or config.skills.global_text_menu ~= false then
        text_popup.start_watcher()
    end

    -- Strict <= 500 MB RAM hygiene timer (Lua GC + C++ malloc_trim/mmap guard)
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20000, function()
        collectgarbage("step", 120)
        if qwen_native and qwen_native.get_memory_stats then
            local ms = qwen_native.get_memory_stats()
            if ms and ms.total_rss_mb and ms.total_rss_mb > 420 then
                pcall(qwen_native.trim_memory)
                collectgarbage("collect")
            end
        end
        return true
    end)

    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 3000, function()
        show_next_data()
        return false
    end)
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.DBUBBLE_CYCLE_MS, show_next_data)
end

return widget
