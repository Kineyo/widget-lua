----------------------------------------------------------------------
-- bubbles.lua  –  Dynamic speech bubbles for general system messages
--                 (weather, clock, crypto, forex, facts, notifications).
--                 ALWAYS appears at the SIDES (left or right of widget),
--                 never on top (so top is clear for song lyrics).
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gtk    = lgi.require("Gtk", "3.0")
local Gdk    = lgi.require("Gdk", "3.0")
local GLib   = lgi.GLib
local cairo  = lgi.cairo
local Pango  = lgi.Pango
local PangoCairo = lgi.PangoCairo

local config = require("config")
local utils  = require("utils")

local bubbles = {}
bubbles.on_next = nil

-- State
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
local is_music_bubble = false

-- Measurement context
local measure_surf = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
local measure_cr   = cairo.Context(measure_surf)

----------------------------------------------------------------------
-- Convert markdown bold/code to Pango markup for speech bubbles
----------------------------------------------------------------------
local function md_to_pango_bubble(text)
    if not text or #text == 0 then return "" end
    local s = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub("%*%*([^\n%*]+)%*%*", '<span weight="bold" foreground="#FFFFFF">%1</span>')
    s = s:gsub("`([^`\n]+)`", '<span font_family="Monospace" foreground="#FDE047">%1</span>')
    return s
end

----------------------------------------------------------------------
-- Measure text accurately with Pango
----------------------------------------------------------------------
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

----------------------------------------------------------------------
-- Create the bubble window (once)
----------------------------------------------------------------------
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
    bubble_win:set_tooltip_text("• Clic: Siguiente dato\n• Clic secundario: Ocultar")

    -- RGBA visual
    local screen = bubble_win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then bubble_win:set_visual(visual) end

    -- Mouse events: click to cycle or dismiss, hover for pointer cursor
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
        if gdk_win then
            gdk_win:set_cursor(nil)
        end
        return false
    end

    bubble_win.on_button_press_event = function(self, event)
        if event.button == 1 then
            -- Left click cycles to next data bubble immediately!
            if bubbles.on_next then
                bubbles.on_next()
            else
                bubbles.hide()
            end
        else
            -- Right or middle click dismisses
            bubbles.hide()
        end
        return true
    end
end

local function detect_bubble_color(text)
    if not text or #text == 0 then return config.ACCENT end
    if text:find("🎵") then
        return config.ACCENT_PINK or { 0.957, 0.447, 0.714 }
    elseif text:find("🔔") then
        return config.NOTIFICATION or { 0.98, 0.60, 0.08 }
    elseif text:find("☀️") or text:find("🌤") or text:find("🌧") or text:find("❄️") or text:find("wttr") or text:find("°C") then
        return config.ACCENT_CYAN or { 0.133, 0.827, 0.933 }
    elseif text:find("₿") or text:find("BTC") or text:find("USD") or text:find("EUR") or text:find("Dólar") or text:find("MXN") then
        return { 0.204, 0.780, 0.349 } -- Emerald
    elseif text:find("CPU") or text:find("RAM") or text:find("🦞") or text:find("Sistema") then
        return config.ACCENT or { 0.545, 0.361, 0.965 }
    else
        return config.ACCENT or { 0.545, 0.361, 0.965 }
    end
end

----------------------------------------------------------------------
-- Draw the dynamic speech-bubble shape with text and tail at the sides
----------------------------------------------------------------------
local function draw_bubble(self, cr)
    local w = self:get_allocated_width()
    local h = self:get_allocated_height()
    local r = 14
    local tail_size = 12
    local pad_x = 16
    local pad_y = 12

    -- Clear
    cr:set_operator(cairo.Operator.SOURCE)
    cr:set_source_rgba(0, 0, 0, 0)
    cr:paint()
    cr:set_operator(cairo.Operator.OVER)

    local bx, by, bw, bh = 0, 0, w, h
    local tail_x1, tail_y1, tail_x2, tail_y2, tail_x3, tail_y3

    local ty = current_ty or math.floor(h / 2)
    ty = math.max(r + 4, math.min(ty, h - r - 4))

    if current_edge == "right" then
        -- Widget on right, bubble on left, tail points RIGHT (➔)
        bw = w - tail_size
        tail_x1, tail_y1 = bw, ty - tail_size + 2
        tail_x2, tail_y2 = w, ty
        tail_x3, tail_y3 = bw, ty + tail_size - 2
    else
        -- Widget on left, bubble on right, tail points LEFT (⬅)
        bx = tail_size
        bw = w - tail_size
        tail_x1, tail_y1 = bx, ty - tail_size + 2
        tail_x2, tail_y2 = 0, ty
        tail_x3, tail_y3 = bx, ty + tail_size - 2
    end

    local bg = config.BG_DBUBBLE or { 0.080, 0.070, 0.135, 0.95 }
    local t = math.max(0, math.min(1, current_opacity))
    local ease_scale = math.max(0.01, 1 - math.pow(1 - t, 3))

    -- 1. Soft diffused shadow
    cr:save()
    for k = 3, 1, -1 do
        cr:new_sub_path()
        utils.rounded_rect(cr, bx, by + 1.5 + k * 0.7, bw, bh, r)
        cr:set_source_rgba(0, 0, 0, 0.04 * (4 - k) * t)
        cr:fill()
    end
    cr:restore()

    -- 2. Draw body and tail with popup scaling animation
    cr:save()
    cr:translate(tail_x2, tail_y2)
    cr:scale(ease_scale, ease_scale)
    cr:translate(-tail_x2, -tail_y2)

    -- Rounded rect path
    cr:new_sub_path()
    cr:arc(bx + bw - r, by + r, r, -math.pi/2, 0)
    cr:arc(bx + bw - r, by + bh - r, r, 0, math.pi/2)
    cr:arc(bx + r, by + bh - r, r, math.pi/2, math.pi)
    cr:arc(bx + r, by + r, r, math.pi, 3*math.pi/2)
    cr:close_path()

    -- Add tail to path
    cr:move_to(tail_x1, tail_y1)
    cr:line_to(tail_x2, tail_y2)
    cr:line_to(tail_x3, tail_y3)
    cr:close_path()

    -- Fill with dark glass gradient
    local pat = cairo.Pattern.create_linear(0, by, 0, by + bh)
    pat:add_color_stop_rgba(0, 0.090, 0.080, 0.150, (bg[4] or 0.95) * t)
    pat:add_color_stop_rgba(1, 0.065, 0.055, 0.115, (bg[4] or 0.95) * t)
    cr:set_source(pat)
    cr:fill_preserve()

    -- Glowing modern hairline border
    local border_col = detect_bubble_color(current_text)
    cr:set_source_rgba(border_col[1], border_col[2], border_col[3], 0.50 * t)
    cr:set_line_width(1.2)
    cr:stroke()

    cr:restore()

    -- Draw text inside bounding box
    if #current_text > 0 then
        cr:save()
        cr:translate(tail_x2, tail_y2)
        cr:scale(ease_scale, ease_scale)
        cr:translate(-tail_x2, -tail_y2)

        local tc = { config.TEXT[1], config.TEXT[2], config.TEXT[3], t }
        local text_x = bx + pad_x
        local text_y = by + math.max(pad_y, math.floor((bh - current_text_h) / 2))

        local layout = PangoCairo.create_layout(cr)
        layout:set_font_description(Pango.FontDescription.from_string(config.FONT_DBUBBLE or "Sans 11"))
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

----------------------------------------------------------------------
-- Cancel any pending timers
----------------------------------------------------------------------
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

----------------------------------------------------------------------
-- Fade animation (smooth and clean)
----------------------------------------------------------------------
local function animate_fade(direction, callback)
    local frame_ms = math.floor(1000 / (config.ANIM_FPS or 60))
    local fade_dur = config.DBUBBLE_FADE_MS or 250
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

----------------------------------------------------------------------
-- Resolve side edge: General messages ALWAYS appear at the sides
----------------------------------------------------------------------
local function resolve_side_edge(bx, bsize)
    local screen = Gdk.Screen.get_default()
    local sw = screen:get_width()
    local s = bsize or config.BUBBLE_SIZE or 72
    local center_x = (bx or 0) + s / 2
    if center_x >= sw / 2 then
        return "right" -- Widget on right half of screen → bubble on left, arrow points right (➔)
    else
        return "left"  -- Widget on left half of screen → bubble on right, arrow points left (⬅)
    end
end

----------------------------------------------------------------------
-- Show a dynamic bubble near the circle widget ALWAYS AT THE SIDES
-- Auto-wraps downwards if text exceeds acceptable width
----------------------------------------------------------------------
function bubbles.show(text, bx, by, bsize, edge, duration_ms)
    ensure_window()
    cancel_timers()

    current_text    = text or ""
    current_opacity = 0
    current_edge    = resolve_side_edge(bx, bsize)
    is_music_bubble = (current_text:sub(1, 4) == "🎵")

    local max_w = config.DBUBBLE_MAX_TEXT_W or 290
    local pad_x = 16
    local pad_y = 12
    local tail_size = 12

    -- Measure text dynamically
    current_text_w, current_text_h, current_wrapped = measure_text(
        current_text, config.FONT_DBUBBLE or "Sans 11", max_w)

    -- Dynamic bubble body dimensions
    local bw = math.max(140, current_text_w + pad_x * 2)
    local bh = math.max(46, current_text_h + pad_y * 2)

    -- Total window dimensions: side bubbles always include tail_size horizontally
    local win_w = bw + tail_size
    local win_h = bh

    local screen = Gdk.Screen.get_default()
    local sw = screen:get_width()
    local sh = screen:get_height()
    local gap = 4

    local x, y
    if current_edge == "right" then
        -- Widget on right, bubble on left, tail points RIGHT (➔)
        x = bx - win_w - gap
    else
        -- Widget on left, bubble on right, tail points LEFT (⬅)
        x = bx + bsize + gap
    end
    y = by + (bsize - win_h) / 2

    -- Strictly clamp so the entire bubble stays on screen
    x = math.max(6, math.min(x, sw - win_w - 6))
    y = math.max(6, math.min(y, sh - win_h - 6))

    -- Target avatar center for arrow alignment
    local target_y = by + math.floor(bsize / 2)
    current_ty = target_y - y
    current_ty = math.max(14, math.min(current_ty, bh - 14))

    bubble_win:set_size_request(win_w, win_h)
    bubble_win:resize(win_w, win_h)
    bubble_win.on_draw = draw_bubble
    bubble_win:move(math.floor(x), math.floor(y))
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

----------------------------------------------------------------------
-- Hide immediately
----------------------------------------------------------------------
function bubbles.hide()
    cancel_timers()
    current_opacity = 0
    if bubble_win then
        bubble_win:hide()
    end
end

----------------------------------------------------------------------
-- Check if visible
----------------------------------------------------------------------
function bubbles.is_visible()
    return current_opacity > 0
end

return bubbles
