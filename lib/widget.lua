----------------------------------------------------------------------
-- widget.lua  –  Circular floating bubble with edge snapping,
--                YouTube Music mini player integration & OpenClaw Agent
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gtk    = lgi.require("Gtk", "3.0")
local Gdk    = lgi.require("Gdk", "3.0")
local GLib   = lgi.GLib
local cairo  = lgi.cairo

local config   = require("config")
local utils    = require("utils")
local animator = require("animator")
local fetchers = require("fetchers")
local dbus_l   = require("dbus_listener")
local chat     = require("chat")
local bubbles  = require("bubbles")
local launcher = require("launcher")
local mpris         = require("mpris")
local player        = require("player")
local lyrics        = require("lyrics")
local lyrics_bubble = require("lyrics_bubble")

local widget = {}
widget.window = nil

-- State
local avatar_pb   = nil
local wx, wy      = 0, 0       -- current window position
local dragging    = false
local is_hovered  = false
local drag_ox, drag_oy = 0, 0  -- offset from click to window origin
local was_drag    = false       -- distinguish click from drag
local snap_edge   = "right"     -- which edge we're snapped to

-- Data bubble cycling
local data_index  = 0
local data_keys   = { "clock", "weather", "music", "crypto", "forex" }

----------------------------------------------------------------------
-- Get screen dimensions
----------------------------------------------------------------------
local function screen_size()
    local screen = Gdk.Screen.get_default()
    return screen:get_width(), screen:get_height()
end

----------------------------------------------------------------------
-- Snap to nearest edge
----------------------------------------------------------------------
local function snap_to_edge(win, from_x, from_y)
    local sw, sh = screen_size()
    local s = config.BUBBLE_SIZE
    local m = config.BUBBLE_MARGIN

    -- Distances to each edge
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
        ty = sh - s - m - 48  -- panel offset
        snap_edge = "bottom"
    end

    -- Clamp vertical/horizontal
    ty = math.max(m, math.min(ty, sh - s - m))
    tx = math.max(m, math.min(tx, sw - s - m))

    -- Animate snap
    local start_x, start_y = from_x, from_y
    local anim = animator.new({
        duration = config.SNAP_DURATION_MS,
        ease = utils.ease_out,
        on_update = function(t)
            local cx = utils.lerp(start_x, tx, t)
            local cy = utils.lerp(start_y, ty, t)
            wx, wy = math.floor(cx), math.floor(cy)
            win:move(wx, wy)
            lyrics_bubble.reposition(wx, wy, config.BUBBLE_SIZE, snap_edge)
            launcher.reposition()
        end,
    })
    anim.value = 0
    anim.forward = true
    anim:start()
end

----------------------------------------------------------------------
-- Show a smart random data bubble
----------------------------------------------------------------------
local function show_next_data()
    local text = fetchers.get_random_fact()
    if text and #text > 0 then
        bubbles.show(text, wx, wy, config.BUBBLE_SIZE, snap_edge)
    end
    return true  -- keep timer
end

----------------------------------------------------------------------
-- Draw the circular bubble
----------------------------------------------------------------------
local function on_draw(self, cr)
    local s = config.BUBBLE_SIZE
    local r = s / 2

    -- Clear to transparent
    cr:set_operator(cairo.Operator.SOURCE)
    cr:set_source_rgba(0, 0, 0, 0)
    cr:paint()
    cr:set_operator(cairo.Operator.OVER)

    local is_playing = (mpris.track.status == "Playing")

    -- 1. Soft diffused ambient shadow
    cr:save()
    for k = 3, 1, -1 do
        cr:arc(r, r + 2 + k * 0.7, r - 3, 0, 2 * math.pi)
        cr:set_source_rgba(0, 0, 0, 0.05 * (4 - k))
        cr:fill()
    end
    cr:restore()

    -- 2. Minimalist subtle glow on hover or playing (clean, no rainbow clutter)
    if is_hovered or is_playing then
        cr:save()
        local glow_r = r
        cr:arc(r, r, glow_r, 0, 2 * math.pi)
        local glow = cairo.Pattern.create_radial(r, r, r - 5, r, r, glow_r)
        local gc = is_playing and config.ACCENT_PINK or config.ACCENT
        glow:add_color_stop_rgba(0, gc[1], gc[2], gc[3], is_hovered and 0.45 or 0.30)
        glow:add_color_stop_rgba(1, gc[1], gc[2], gc[3], 0.0)
        cr:set_source(glow)
        cr:fill()
        cr:restore()
    end

    -- 3. Dark circle background
    local inner_r = r - config.GLOW_WIDTH
    cr:save()
    cr:arc(r, r, inner_r, 0, 2 * math.pi)
    utils.set_colour(cr, config.BG)
    cr:fill()
    cr:restore()

    -- 4. Avatar / Icon circular clip (conserves avatar & icon)
    if avatar_pb then
        utils.draw_avatar(cr, avatar_pb, r, r, inner_r - 0.5)
    else
        cr:save()
        cr:arc(r, r, inner_r - 0.5, 0, 2 * math.pi)
        cr:set_source_rgba(config.ACCENT[1], config.ACCENT[2], config.ACCENT[3], 0.25)
        cr:fill()
        utils.draw_text(cr, r - 8, r - 10, "✦", "Sans 16", { 1, 1, 1, 0.9 }, 24)
        cr:restore()
    end

    -- 5. Modern minimalist hairline ring border
    cr:save()
    cr:arc(r, r, inner_r, 0, 2 * math.pi)
    local ring_col
    local ring_alpha
    if is_playing then
        ring_col = config.ACCENT_PINK
        ring_alpha = 0.90
    elseif is_hovered then
        ring_col = config.ACCENT
        ring_alpha = 0.85
    else
        ring_col = { 0.45, 0.40, 0.60 }
        ring_alpha = 0.40
    end
    cr:set_source_rgba(ring_col[1], ring_col[2], ring_col[3], ring_alpha)
    cr:set_line_width(1.2)
    cr:stroke()
    cr:restore()

    -- 6. Modern badges preserving emojis
    -- Music playing indicator (subtle pill badge with 🎵 on bottom-left)
    if is_playing then
        local bx, by, br = 14, s - 14, 9.5
        cr:save()
        cr:arc(bx, by, br, 0, 2 * math.pi)
        cr:set_source_rgba(0.08, 0.07, 0.14, 0.95)
        cr:fill_preserve()
        cr:set_source_rgba(config.ACCENT_PINK[1], config.ACCENT_PINK[2], config.ACCENT_PINK[3], 0.85)
        cr:set_line_width(1.1)
        cr:stroke()
        utils.draw_text(cr, bx - 5.5, by - 6.5, "🎵", "Sans 8", { 1, 1, 1, 1 }, 14)
        cr:restore()
    end

    -- Notification indicator (subtle badge with 🔔 on top-right)
    if dbus_l.has_badge then
        local nx, ny, nr = s - 14, 14, 8.5
        cr:save()
        cr:arc(nx, ny, nr, 0, 2 * math.pi)
        cr:set_source_rgba(1.0, 0.45, 0.0, 0.95)
        cr:fill_preserve()
        cr:set_source_rgba(1.0, 1.0, 1.0, 0.85)
        cr:set_line_width(1.0)
        cr:stroke()
        utils.draw_text(cr, nx - 4.5, ny - 5.5, "🔔", "Sans 7", { 1, 1, 1, 1 }, 12)
        cr:restore()
    end

    return true
end

----------------------------------------------------------------------
-- Build the bubble window
----------------------------------------------------------------------
function widget.build()
    local s = config.BUBBLE_SIZE

    local win = Gtk.Window {
        type = Gtk.WindowType.POPUP,
        title = "OpenClaw Qwen Widget",
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
    win:set_tooltip_text("✦ Qwen Widget\n• Clic: Abrir Chat AI\n• Clic derecho o Scroll: Info / Burbuja\n• Clic central: Música")

    -- RGBA
    local screen = win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then win:set_visual(visual) end

    -- Load avatar (with fallback to icon.png if needed to preserve icon)
    avatar_pb = utils.load_pixbuf(config.AVATAR, config.BUBBLE_SIZE)
    if not avatar_pb then
        avatar_pb = utils.load_pixbuf(config.ASSETS_DIR .. "/icon.png", config.BUBBLE_SIZE)
    end

    -- Events (click, drag, hover, scroll)
    win:add_events(
        Gdk.EventMask.BUTTON_PRESS_MASK +
        Gdk.EventMask.BUTTON_RELEASE_MASK +
        Gdk.EventMask.POINTER_MOTION_MASK +
        Gdk.EventMask.ENTER_NOTIFY_MASK +
        Gdk.EventMask.LEAVE_NOTIFY_MASK +
        Gdk.EventMask.SCROLL_MASK)

    win.on_draw = on_draw

    -- Hover events: minimalist visual feedback only (NO radial options popping up!)
    win.on_enter_notify_event = function(self, event)
        if not dragging then
            is_hovered = true
            local gdk_win = win:get_window()
            if gdk_win then
                local display = gdk_win:get_display()
                local cursor = Gdk.Cursor.new_from_name(display, "pointer")
                gdk_win:set_cursor(cursor)
            end
            win:queue_draw()
        end
        return false
    end

    win.on_leave_notify_event = function(self, event)
        is_hovered = false
        local gdk_win = win:get_window()
        if gdk_win then
            gdk_win:set_cursor(nil)
        end
        win:queue_draw()
        return false
    end

    -- Scroll event on orb: immediately invoke / cycle data bubble!
    win.on_scroll_event = function(self, event)
        lyrics_bubble.hide()
        show_next_data()
        return true
    end

    -- Mouse press → start drag, click, toggle player, or right-click to invoke data bubble
    win.on_button_press_event = function(self, event)
        -- Double left click → immediately show / cycle data bubble
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
            -- Middle-click → Toggle YouTube Music Mini Player!
            player.toggle(wx, wy, config.BUBBLE_SIZE, snap_edge)
            return true
        elseif event.button == 3 then
            -- Right-click → Instantly invoke / cycle data bubble!
            lyrics_bubble.hide()
            show_next_data()
            return true
        end
        return false
    end

    -- Mouse motion → drag
    win.on_motion_notify_event = function(self, event)
        if dragging then
            local nx = event.x_root - drag_ox
            local ny = event.y_root - drag_oy
            -- If moved more than 5px, it's a drag not a click
            if math.abs(nx - wx) > 5 or math.abs(ny - wy) > 5 then
                was_drag = true
            end
            wx, wy = math.floor(nx), math.floor(ny)
            win:move(wx, wy)
            -- Hide bubbles while dragging
            bubbles.hide()
            lyrics_bubble.reposition(wx, wy, config.BUBBLE_SIZE, snap_edge)
            return true
        end
        return false
    end

    -- Mouse release → snap or toggle chat
    win.on_button_release_event = function(self, event)
        if event.button == 1 then
            dragging = false
            if was_drag then
                -- Snap to nearest edge
                snap_to_edge(win, wx, wy)
            else
                -- Click → toggle chat menu (hide any active bubbles first)
                bubbles.hide()
                lyrics_bubble.hide()
                chat.build(win)
                chat.toggle(wx, wy, config.BUBBLE_SIZE, snap_edge)
            end
            return true
        end
        return false
    end

    -- Connect callbacks for chat and bubbles
    chat.on_invoke_bubble = function()
        show_next_data()
    end
    bubbles.on_next = function()
        show_next_data()
    end

    -- Connect Launcher callbacks
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
                        bubbles.show("📊 " .. res:gsub("\n+", " • "), wx, wy, config.BUBBLE_SIZE, snap_edge, 14000)
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
                        bubbles.show("📸 " .. res, wx, wy, config.BUBBLE_SIZE, snap_edge, 8000)
                        return false
                    end)
                end)
            end
        elseif action_id == "quit" then
            Gtk.main_quit()
        end
    end

    -- Redraw on data update
    fetchers.on_update = function()
        win:queue_draw()
    end

    -- Redraw on media player status change
    mpris.on_status_change = function(status)
        win:queue_draw()
        if config.LYRICS_ENABLED then
            lyrics.set_status(status)
        end
    end

    -- When YouTube Music changes song: show dynamic text bubble for 12 seconds
    -- and load synchronized lyrics bubble from the top of the widget
    mpris.on_track_change = function(track)
        win:queue_draw()
        if player.update_ui then player.update_ui() end
        if track and #track.title > 0 and track.status ~= "Stopped" then
            local song_text = "🎵 " .. track.title
            if track.artist and #track.artist > 0 and track.artist ~= "YouTube Music" then
                song_text = song_text .. " — " .. track.artist
            end
            bubbles.show(song_text, wx, wy, config.BUBBLE_SIZE, snap_edge, 12000)
        end
        if config.LYRICS_ENABLED then
            lyrics.set_track(track)
        end
    end

    -- Connect synchronized lyrics to speech bubble on top of widget
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
        if config.LYRICS_ENABLED then
            lyrics.set_status(status)
        end
    end)

    -- DBus notification → show as dynamic bubble
    dbus_l.on_notify = function()
        if dbus_l.notification then
            local notif = dbus_l.notification
            local text = "🔔 " .. (notif.summary or "")
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

----------------------------------------------------------------------
-- Start the widget
----------------------------------------------------------------------
function widget.start()
    local win = widget.window
    if not win then return end

    -- Initial position: bottom-right
    local sw, sh = screen_size()
    wx = sw - config.BUBBLE_SIZE - config.BUBBLE_MARGIN
    wy = sh - config.BUBBLE_SIZE - config.BUBBLE_MARGIN - 60
    snap_edge = "right"

    win:move(wx, wy)
    win:show_all()
    win:set_opacity(0)

    -- Fade in
    animator.fade(win, "in")

    -- Start data fetchers
    fetchers.start()

    -- Start DBus listener
    dbus_l.start()

    -- Start MPRIS YouTube Music listener & player
    mpris.start()

    -- Check if music is already playing on startup to load lyrics immediately
    if config.LYRICS_ENABLED then
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, function()
            if mpris.track and #mpris.track.title > 0 and mpris.track.status == "Playing" then
                lyrics.set_track(mpris.track)
            end
            return false
        end)
    end

    -- Start data bubble cycling (first one after 3 seconds)
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 3000, function()
        show_next_data()
        return false
    end)
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.DBUBBLE_CYCLE_MS, show_next_data)
end

return widget
