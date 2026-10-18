----------------------------------------------------------------------
-- bubbles.lua  –  Dynamic speech bubbles for system & financial info
--                 Zero emojis, automatic screen clamping, and real-time
--                 repositioning when the main bubble moves.
----------------------------------------------------------------------
local lgi        = require("lgi")
local Gtk        = lgi.require("Gtk", "3.0")
local Gdk        = lgi.require("Gdk", "3.0")
local GLib       = lgi.GLib
local cairo      = lgi.cairo
local Pango      = lgi.Pango
local PangoCairo = lgi.PangoCairo

local config = require("config")
local utils  = require("utils")

local bubbles = {}
bubbles.on_next = nil

local bubble_win      = nil
local fade_timer      = nil
local hide_timer      = nil
local current_opacity = 0
local current_text    = ""
local current_edge    = "right"
local current_ty      = nil
local current_text_w  = 0
local current_text_h  = 0
local current_wrapped = false
local last_bx, last_by = 0, 0
local last_bsize       = config.BUBBLE_SIZE or 72

local measure_surf = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
local measure_cr   = cairo.Context(measure_surf)

local function md_to_pango_bubble(text)
    if not text or #text == 0 then return "" end
    local s = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub("%*%*([^\n%*]+)%*%*", '<span weight="bold" foreground="#FFFFFF">%1</span>')
    s = s:gsub("`([^`\n]+)`", '<span font_family="Monospace" foreground="#93C5FD">%1</span>')
    s = s:gsub("^%[(.-)%]", '<span weight="bold" foreground="#60A5FA">[%1]</span>')
    return s
end

local function measure_text(text, font_desc, max_content_w)
    local layout = PangoCairo.create_layout(measure_cr)
    layout:set_font_description(Pango.FontDescription.from_string(font_desc))
    local markup = md_to_pango_bubble(text)
    local ok = pcall(function() layout:set_markup(markup, -1) end)
    if not ok then layout:set_text(text, -1) end

    local _, natural = layout:get_pixel_extents()
    local nw = math.ceil(natural.width)
    local nh = math.ceil(natural.height)

    if nw <= max_content_w then
        return nw, nh, false
    else
        layout:set_width(max_content_w * Pango.SCALE)
        layout:set_wrap(Pango.WrapMode.WORD_CHAR)
        local _, wrapped = layout:get_pixel_extents()
        return max_content_w, math.ceil(wrapped.height), true
    end
end

local function ensure_window()
    if bubble_win then return end

    bubble_win = Gtk.Window {
        type = Gtk.WindowType.POPUP,
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = false,
        accept_focus = false,
        type_hint = Gdk.WindowTypeHint.TOOLTIP,
    }
    bubble_win:set_keep_above(true)
    bubble_win:set_app_paintable(true)
    bubble_win:set_tooltip_text("Clic izquierdo: Siguiente dato | Clic derecho: Ocultar")

    local screen = bubble_win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then bubble_win:set_visual(visual) end

    bubble_win:add_events(
        Gdk.EventMask.BUTTON_PRESS_MASK +
        Gdk.EventMask.ENTER_NOTIFY_MASK +
        Gdk.EventMask.LEAVE_NOTIFY_MASK)

    bubble_win.on_enter_notify_event = function(self)
        local gdk_win = self:get_window()
        if gdk_win then
            local display = gdk_win:get_display()
            local cursor = Gdk.Cursor.new_from_name(display, "pointer")
            gdk_win:set_cursor(cursor)
        end
        return false
    end

    bubble_win.on_leave_notify_event = function(self)
        local gdk_win = self:get_window()
        if gdk_win then gdk_win:set_cursor(nil) end
        return false
    end

    bubble_win.on_button_press_event = function(_, event)
        if event.button == 1 then
            if bubbles.on_next then
                bubbles.on_next()
            else
                bubbles.hide()
            end
        else
            bubbles.hide()
        end
        return true
    end
end

local function detect_bubble_color(text)
    if not text or #text == 0 then return config.ACCENT end
    if text:find("Music") or text:find("Spotify") then
        return config.ACCENT_PINK or { 0.925, 0.365, 0.640 }
    elseif text:find("Notificacion") or text:find("Aviso") then
        return config.NOTIFICATION or { 0.96, 0.62, 0.04 }
    elseif text:find("Clima") then
        return config.ACCENT_CYAN or { 0.133, 0.827, 0.933 }
    elseif text:find("BTC") or text:find("ETH") or text:find("SOL") or text:find("USD") or text:find("EUR") then
        return { 0.204, 0.780, 0.349 }
    else
        return config.ACCENT or { 0.380, 0.540, 0.980 }
    end
end

local function draw_bubble(self, cr)
    local w = self:get_allocated_width()
    local h = self:get_allocated_height()
    local r = 12
    local tail_size = 11
    local pad_x = 15
    local pad_y = 11

    cr:set_operator(cairo.Operator.SOURCE)
    cr:set_source_rgba(0, 0, 0, 0)
    cr:paint()
    cr:set_operator(cairo.Operator.OVER)

    local bx, by, bw, bh = 0, 0, w, h
    local tail_x1, tail_y1, tail_x2, tail_y2, tail_x3, tail_y3

    local ty = current_ty or math.floor(h / 2)
    ty = math.max(r + 4, math.min(ty, h - r - 4))

    if current_edge == "right" then
        bw = w - tail_size
        tail_x1, tail_y1 = bw, ty - tail_size + 2
        tail_x2, tail_y2 = w, ty
        tail_x3, tail_y3 = bw, ty + tail_size - 2
    else
        bx = tail_size
        bw = w - tail_size
        tail_x1, tail_y1 = bx, ty - tail_size + 2
        tail_x2, tail_y2 = 0, ty
        tail_x3, tail_y3 = bx, ty + tail_size - 2
    end

    local bg = config.BG_DBUBBLE or { 0.075, 0.082, 0.133, 0.96 }
    local t = math.max(0, math.min(1, current_opacity))
    local ease_scale = math.max(0.01, 1 - math.pow(1 - t, 3))

    cr:save()
    for k = 3, 1, -1 do
        cr:new_sub_path()
        utils.rounded_rect(cr, bx, by + 1.5 + k * 0.7, bw, bh, r)
        cr:set_source_rgba(0, 0, 0, 0.04 * (4 - k) * t)
        cr:fill()
    end
    cr:restore()

    cr:save()
    cr:translate(tail_x2, tail_y2)
    cr:scale(ease_scale, ease_scale)
    cr:translate(-tail_x2, -tail_y2)

    cr:new_sub_path()
    cr:arc(bx + bw - r, by + r, r, -math.pi/2, 0)
    cr:arc(bx + bw - r, by + bh - r, r, 0, math.pi/2)
    cr:arc(bx + r, by + bh - r, r, math.pi/2, math.pi)
    cr:arc(bx + r, by + r, r, math.pi, 3*math.pi/2)
    cr:close_path()

    cr:move_to(tail_x1, tail_y1)
    cr:line_to(tail_x2, tail_y2)
    cr:line_to(tail_x3, tail_y3)
    cr:close_path()

    local pat = cairo.Pattern.create_linear(0, by, 0, by + bh)
    pat:add_color_stop_rgba(0, 0.085, 0.095, 0.155, (bg[4] or 0.96) * t)
    pat:add_color_stop_rgba(1, 0.055, 0.065, 0.110, (bg[4] or 0.96) * t)
    cr:set_source(pat)
    cr:fill_preserve()

    local border_col = detect_bubble_color(current_text)
    cr:set_source_rgba(border_col[1], border_col[2], border_col[3], 0.55 * t)
    cr:set_line_width(1.2)
    cr:stroke()
    cr:restore()

    if #current_text > 0 then
        cr:save()
        cr:translate(tail_x2, tail_y2)
        cr:scale(ease_scale, ease_scale)
        cr:translate(-tail_x2, -tail_y2)

        local tc = { config.TEXT[1], config.TEXT[2], config.TEXT[3], t }
        local text_x = bx + pad_x
        local text_y = by + math.max(pad_y, math.floor((bh - current_text_h) / 2))

        local layout = PangoCairo.create_layout(cr)
        layout:set_font_description(Pango.FontDescription.from_string(config.FONT_DBUBBLE or "Sans 10.5"))
        local markup = md_to_pango_bubble(current_text)
        local ok = pcall(function() layout:set_markup(markup, -1) end)
        if not ok then layout:set_text(current_text, -1) end
        if current_wrapped or current_text_w >= (config.DBUBBLE_MAX_TEXT_W or 290) then
            layout:set_width((config.DBUBBLE_MAX_TEXT_W or 290) * Pango.SCALE)
            layout:set_wrap(Pango.WrapMode.WORD_CHAR)
        end
        utils.set_colour(cr, tc)
        cr:move_to(text_x, text_y)
        PangoCairo.show_layout(cr, layout)
        cr:restore()
    end

    return true
end

local function cancel_timers()
    if fade_timer then
        pcall(function() GLib.source_remove(fade_timer) end)
        fade_timer = nil
    end
    if hide_timer then
        pcall(function() GLib.source_remove(hide_timer) end)
        hide_timer = nil
    end
end

local function animate_fade(direction, callback)
    local frame_ms = math.floor(1000 / (config.ANIM_FPS or 60))
    local fade_dur = config.DBUBBLE_FADE_MS or 200
    local step = frame_ms / fade_dur

    if fade_timer then
        pcall(function() GLib.source_remove(fade_timer) end)
        fade_timer = nil
    end

    fade_timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, frame_ms, function()
        if direction == "in" then
            current_opacity = current_opacity + step
            if current_opacity >= 1.0 then
                current_opacity = 1.0
                if bubble_win then bubble_win:queue_draw() end
                fade_timer = nil
                if callback then callback() end
                return false
            end
        else
            current_opacity = current_opacity - step
            if current_opacity <= 0.0 then
                current_opacity = 0.0
                fade_timer = nil
                if bubble_win then
                    bubble_win:queue_draw()
                    bubble_win:hide()
                end
                if callback then callback() end
                return false
            end
        end
        if bubble_win then bubble_win:queue_draw() end
        return true
    end)
end

local function resolve_side_edge(bx, bsize)
    local sw = utils.screen_size()
    local s = bsize or config.BUBBLE_SIZE or 72
    local center_x = (bx or 0) + s / 2
    if center_x >= sw / 2 then
        return "right"
    else
        return "left"
    end
end

local function compute_and_move(bx, by, bsize)
    local max_w = config.DBUBBLE_MAX_TEXT_W or 290
    local pad_x = 15
    local pad_y = 11
    local tail_size = 11

    current_edge = resolve_side_edge(bx, bsize)
    current_text_w, current_text_h, current_wrapped = measure_text(
        current_text, config.FONT_DBUBBLE or "Sans 10.5", max_w)

    local bw = math.max(140, current_text_w + pad_x * 2)
    local bh = math.max(44, current_text_h + pad_y * 2)
    local win_w = bw + tail_size
    local win_h = bh
    local gap = 6

    local x
    if current_edge == "right" then
        x = bx - win_w - gap
    else
        x = bx + bsize + gap
    end
    local y = by + (bsize - win_h) / 2
    x, y = utils.clamp_to_screen(x, y, win_w, win_h, 6)

    local target_y = by + math.floor(bsize / 2)
    current_ty = math.max(14, math.min(target_y - y, bh - 14))

    bubble_win:set_size_request(win_w, win_h)
    bubble_win:resize(win_w, win_h)
    bubble_win:move(x, y)
end

function bubbles.reposition(bx, by, bsize)
    last_bx = bx or last_bx
    last_by = by or last_by
    last_bsize = bsize or last_bsize
    if bubble_win and current_opacity > 0 and #current_text > 0 then
        compute_and_move(last_bx, last_by, last_bsize)
        bubble_win:queue_draw()
    end
end

function bubbles.show(text, bx, by, bsize, edge, duration_ms)
    ensure_window()
    cancel_timers()

    last_bx = bx or last_bx
    last_by = by or last_by
    last_bsize = bsize or last_bsize
    current_text    = text or ""
    current_opacity = 0

    compute_and_move(last_bx, last_by, last_bsize)
    bubble_win.on_draw = draw_bubble
    bubble_win:show_all()
    bubble_win:queue_draw()

    local show_duration = duration_ms or config.DBUBBLE_SHOW_MS or 12000
    animate_fade("in", function()
        hide_timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, show_duration, function()
            hide_timer = nil
            animate_fade("out")
            return false
        end)
    end)
end

function bubbles.hide()
    cancel_timers()
    current_opacity = 0
    if bubble_win then
        bubble_win:hide()
    end
end

function bubbles.is_visible()
    return current_opacity > 0
end

return bubbles
