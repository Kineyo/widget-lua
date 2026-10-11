----------------------------------------------------------------------
-- lyrics_bubble.lua  –  Floating Speech Bubble for YouTube Music Lyrics
--                       ALWAYS VERTICAL: ARRIBA (above) or ABAJO (below).
--                       - ARRIBA (default) → arrow at bottom points DOWN (⬇) to avatar
--                       - ABAJO (top edge)  → arrow at top points UP (⬆) to avatar
--                       Never appears at the sides, leaving left & right
--                       clear for general data messages (weather, clock, etc).
----------------------------------------------------------------------
local lgi        = require("lgi")
local Gtk        = lgi.require("Gtk", "3.0")
local Gdk        = lgi.require("Gdk", "3.0")
local GLib       = lgi.GLib
local cairo      = lgi.cairo
local Pango      = lgi.Pango
local PangoCairo = lgi.PangoCairo

local config     = require("config")
local utils      = require("utils")

local lyrics_bubble = {}

-- State
local bubble_win      = nil
local fade_timer      = nil
local current_opacity = 0
local current_text    = ""
local current_text_w  = 0
local current_text_h  = 0
local current_wrapped = false
local current_edge    = "bottom"
local current_tx      = 0
local current_ty      = 0

-- Position cache
local last_wx, last_wy = 0, 0
local last_bsize       = config.BUBBLE_SIZE or 72
local last_snap_edge   = "bottom"

-- Measurement context
local measure_surf = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
local measure_cr   = cairo.Context(measure_surf)

----------------------------------------------------------------------
-- XML escape helper for Pango
----------------------------------------------------------------------
local function escape_markup(text)
    if not text or #text == 0 then return "" end
    return text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

----------------------------------------------------------------------
-- Format text with YouTube Music musical note styling
----------------------------------------------------------------------
local function format_lyrics_markup(text)
    local esc = escape_markup(text)
    return string.format(
        '<span foreground="#FF69B4" weight="bold">♪ </span>' ..
        '<span foreground="#FFFFFF" weight="bold">%s</span>' ..
        '<span foreground="#FF69B4" weight="bold"> ♪</span>',
        esc
    )
end

----------------------------------------------------------------------
-- Measure text accurately with Pango
----------------------------------------------------------------------
local function measure_text(text, font_desc, max_content_w)
    local layout = PangoCairo.create_layout(measure_cr)
    layout:set_font_description(Pango.FontDescription.from_string(font_desc))
    local markup = format_lyrics_markup(text)
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
-- Create the lyrics bubble window (once)
----------------------------------------------------------------------
local function ensure_window()
    if bubble_win then return end

    bubble_win = Gtk.Window {
        type = Gtk.WindowType.POPUP,
        title = "YouTube Music Lyrics Bubble",
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = false,
        accept_focus = false,
        type_hint = Gdk.WindowTypeHint.TOOLTIP,
    }
    bubble_win:set_keep_above(true)
    bubble_win:set_app_paintable(true)

    -- RGBA visual for transparency
    local screen = bubble_win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then bubble_win:set_visual(visual) end

    -- Click on bubble to dismiss / silence lyrics immediately
    bubble_win:add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
    bubble_win.on_button_press_event = function()
        lyrics_bubble.hide()
        return true
    end
end

----------------------------------------------------------------------
-- Draw speech bubble with seamless tail pointing towards the widget
----------------------------------------------------------------------
local function draw_bubble(self, cr)
    local w = self:get_allocated_width()
    local h = self:get_allocated_height()
    local r = 13
    local tail_size = 12
    local tail_half = 8
    local pad_x = 16
    local pad_y = 10

    -- Clear background
    cr:set_operator(cairo.Operator.SOURCE)
    cr:set_source_rgba(0, 0, 0, 0)
    cr:paint()
    cr:set_operator(cairo.Operator.OVER)

    local tx = current_tx or math.floor(w / 2)
    local ty = current_ty or math.floor(h / 2)
    local t = math.max(0, math.min(1, current_opacity))

    -- Subtle popup scale animation anchored at the tail tip
    local ease_scale = math.max(0.01, 1 - math.pow(1 - t, 3))
    cr:save()
    cr:translate(tx, ty)
    cr:scale(ease_scale, ease_scale)
    cr:translate(-tx, -ty)

    -- Continuous path for body and tail without internal seam line
    cr:new_sub_path()
    if current_edge == "top" then
        -- Tail on top edge pointing TOP/UP (⬆) towards avatar above
        local by = tail_size
        local bh = h - tail_size
        cr:arc(r, by + r, r, math.pi, 3*math.pi/2)
        cr:line_to(tx - tail_half, by)
        cr:line_to(tx, 0)
        cr:line_to(tx + tail_half, by)
        cr:arc(w - r, by + r, r, -math.pi/2, 0)
        cr:arc(w - r, h - r, r, 0, math.pi/2)
        cr:arc(r, h - r, r, math.pi/2, math.pi)
        cr:close_path()
    else
        -- Default (bottom): Tail on bottom edge pointing BOTTOM/DOWN (⬇) towards avatar below
        local bh = h - tail_size
        cr:arc(r, r, r, math.pi, 3*math.pi/2)
        cr:arc(w - r, r, r, -math.pi/2, 0)
        cr:arc(w - r, bh - r, r, 0, math.pi/2)
        cr:line_to(tx + tail_half, bh)
        cr:line_to(tx, h)
        cr:line_to(tx - tail_half, bh)
        cr:arc(r, bh - r, r, math.pi/2, math.pi)
        cr:close_path()
    end

    -- Background fill with dark glass gradient
    local bg = config.BG_LYRICS or { 0.08, 0.08, 0.15, 0.94 }
    local pat = cairo.Pattern.create_linear(0, 0, 0, h)
    pat:add_color_stop_rgba(0, 0.11, 0.09, 0.20, (bg[4] or 0.94) * t)
    pat:add_color_stop_rgba(1, 0.06, 0.05, 0.13, (bg[4] or 0.94) * t)
    cr:set_source(pat)
    cr:fill_preserve()

    -- Neon pink accent border (#F472B6)
    local border = config.BORDER_LYRICS or config.ACCENT_PINK or { 0.957, 0.447, 0.714, 0.85 }
    cr:set_source_rgba(border[1], border[2], border[3], (border[4] or 0.85) * t)
    cr:set_line_width(1.3)
    cr:stroke()

    -- Draw lyrics text inside
    if #current_text > 0 then
        local font_desc = config.FONT_LYRICS or "Sans Bold 11"
        local layout = PangoCairo.create_layout(cr)
        layout:set_font_description(Pango.FontDescription.from_string(font_desc))
        local markup = format_lyrics_markup(current_text)
        local ok = pcall(function() layout:set_markup(markup, -1) end)
        if not ok then layout:set_text(current_text, -1) end

        local body_y = (current_edge == "top") and tail_size or 0
        local body_w = w
        local body_h = h - tail_size

        local content_w = body_w - pad_x * 2
        layout:set_width(content_w * Pango.SCALE)
        if current_wrapped then
            layout:set_wrap(Pango.WrapMode.WORD_CHAR)
        end
        layout:set_alignment(Pango.Alignment.CENTER)

        local text_x = pad_x
        local text_y = body_y + math.max(pad_y, math.floor((body_h - current_text_h) / 2))

        cr:move_to(text_x, text_y)
        PangoCairo.show_layout(cr, layout)
    end

    cr:restore()
    return true
end

----------------------------------------------------------------------
-- Fade animation
----------------------------------------------------------------------
local function cancel_fade()
    if fade_timer then
        pcall(function() GLib.source_remove(fade_timer) end)
        fade_timer = nil
    end
end

local function animate_fade(direction, callback)
    local frame_ms = math.floor(1000 / (config.ANIM_FPS or 60))
    local fade_dur = config.LYRICS_FADE_MS or 180
    local step = frame_ms / fade_dur

    cancel_fade()

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
-- Calculate window dimensions and tail geometry for lyrics bubble
-- Positions are ALWAYS VERTICAL: ARRIBA (above avatar) or ABAJO (below avatar).
-- Arrow/tail ALWAYS points directly towards the avatar bubble circle.
----------------------------------------------------------------------
local function compute_geometry(wx, wy, bsize, snap_edge)
    local max_w = config.LYRICS_MAX_W or 320
    local min_w = config.LYRICS_MIN_W or 130
    local pad_x = 16
    local pad_y = 10
    local tail_size = 12
    local gap = config.LYRICS_GAP or 6
    local r = 13
    local tail_half = 8

    current_text_w, current_text_h, current_wrapped = measure_text(
        current_text, config.FONT_LYRICS or "Sans Bold 11", max_w)

    local bw = math.max(min_w, math.min(current_text_w + pad_x * 2, max_w + pad_x * 2))
    local bh = math.max(42, current_text_h + pad_y * 2)

    local screen = Gdk.Screen.get_default()
    local sw = screen:get_width()
    local sh = screen:get_height()

    local win_w = bw
    local win_h = bh + tail_size

    -- Center horizontally over the avatar circle
    local x = wx + (bsize - win_w) / 2
    x = math.max(8, math.min(x, sw - win_w - 8))

    -- Target horizontal center of the avatar for the arrow tip
    local target_x = wx + math.floor(bsize / 2)
    local tx = target_x - x
    tx = math.max(r + tail_half + 2, math.min(tx, bw - r - tail_half - 2))

    local y, ty, edge
    -- Positions are ALWAYS ARRIBA or ABAJO:
    -- Prefer ARRIBA (above avatar) always. Only switch to ABAJO (below avatar)
    -- if widget is docked or located at the top edge of screen where space above is lacking.
    if snap_edge == "top" or (wy - win_h - gap < 8) then
        -- ABAJO (Below avatar): bubble is placed below, tail at top edge points UP (⬆) to avatar
        y = wy + bsize + gap
        y = math.max(8, math.min(y, sh - win_h - 8))
        ty = 0
        edge = "top"
    else
        -- ARRIBA (Above avatar): bubble is placed above, tail at bottom edge points DOWN (⬇) to avatar
        y = wy - win_h - gap
        y = math.max(8, math.min(y, sh - win_h - 8))
        ty = win_h
        edge = "bottom"
    end

    return math.floor(x), math.floor(y), win_w, win_h, edge, tx, ty
end

----------------------------------------------------------------------
-- Show or dynamically update the current lyrics line/paragraph
----------------------------------------------------------------------
function lyrics_bubble.show_line(text, wx, wy, bsize, snap_edge)
    if not text or #text == 0 then
        lyrics_bubble.hide()
        return
    end

    ensure_window()

    last_wx = wx or last_wx
    last_wy = wy or last_wy
    last_bsize = bsize or last_bsize
    last_snap_edge = snap_edge or last_snap_edge

    current_text = text

    local x, y, win_w, win_h, edge, tx, ty = compute_geometry(last_wx, last_wy, last_bsize, last_snap_edge)
    current_edge = edge
    current_tx = tx
    current_ty = ty

    bubble_win:set_size_request(win_w, win_h)
    bubble_win:resize(win_w, win_h)
    bubble_win:move(x, y)
    bubble_win.on_draw = draw_bubble

    if current_opacity >= 0.9 and bubble_win:get_visible() then
        -- Smooth dynamic update in place: redraw immediately without blink
        bubble_win:queue_draw()
    else
        -- Fade in smoothly
        current_opacity = 0
        bubble_win:show_all()
        bubble_win:queue_draw()
        animate_fade("in")
    end
end

----------------------------------------------------------------------
-- Reposition bubble during widget drag or snap
----------------------------------------------------------------------
function lyrics_bubble.reposition(wx, wy, bsize, snap_edge)
    last_wx = wx or last_wx
    last_wy = wy or last_wy
    last_bsize = bsize or last_bsize
    last_snap_edge = snap_edge or last_snap_edge

    if bubble_win and current_opacity > 0 and #current_text > 0 then
        local x, y, win_w, win_h, edge, tx, ty = compute_geometry(last_wx, last_wy, last_bsize, last_snap_edge)
        current_edge = edge
        current_tx = tx
        current_ty = ty

        bubble_win:set_size_request(win_w, win_h)
        bubble_win:resize(win_w, win_h)
        bubble_win:move(x, y)
        bubble_win:queue_draw()
    end
end

----------------------------------------------------------------------
-- Hide lyrics bubble smoothly
----------------------------------------------------------------------
function lyrics_bubble.hide()
    cancel_fade()
    if not bubble_win or current_opacity <= 0 then
        if bubble_win then bubble_win:hide() end
        current_opacity = 0
        current_text = ""
        return
    end

    animate_fade("out", function()
        current_text = ""
    end)
end

----------------------------------------------------------------------
-- Check visibility
----------------------------------------------------------------------
function lyrics_bubble.is_visible()
    return current_opacity > 0
end

return lyrics_bubble
