----------------------------------------------------------------------
-- utils.lua  –  Cairo / Pango drawing helpers & Automatic Fallbacks
--               Includes native C++ coordinate clamping & sprite loader
----------------------------------------------------------------------
local lgi        = require("lgi")
local cairo      = lgi.cairo
local Pango      = lgi.Pango
local PangoCairo = lgi.PangoCairo
local GdkPixbuf  = lgi.GdkPixbuf
local Gdk        = lgi.require("Gdk", "3.0")

local config = require("config")
local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local utils = {}

local DEFAULT_COLOR = { 0.94, 0.95, 0.98, 1.0 }
local DEFAULT_FONT  = "Sans 11"

----------- Safe Screen Dimensions Fallback --------------------------
function utils.screen_size()
    local ok, sw, sh = pcall(function()
        local screen = Gdk.Screen.get_default()
        return screen:get_width(), screen:get_height()
    end)
    if ok and sw and sh and sw > 100 and sh > 100 then
        return sw, sh
    end
    return 1920, 1080
end

----------- Native Screen Clamping Fallback --------------------------
function utils.clamp_to_screen(x, y, w, h, margin)
    local sw, sh = utils.screen_size()
    local m = margin or 8
    x = tonumber(x) or m
    y = tonumber(y) or m
    w = tonumber(w) or 100
    h = tonumber(h) or 100
    if qwen_native and qwen_native.clamp_rect then
        local cx, cy = qwen_native.clamp_rect(x, y, w, h, sw, sh, m)
        return cx, cy
    end
    local cx = math.max(m, math.min(x, sw - w - m))
    local cy = math.max(m, math.min(y, sh - h - m))
    return math.floor(cx), math.floor(cy)
end

----------- Native Dock Coordinate Computation -----------------------
function utils.compute_dock(bx, by, bsize, pw, ph, gap, edge, margin)
    local sw, sh = utils.screen_size()
    bx = tonumber(bx) or 0
    by = tonumber(by) or 0
    bsize = tonumber(bsize) or config.BUBBLE_SIZE or 72
    pw = tonumber(pw) or 350
    ph = tonumber(ph) or 160
    gap = tonumber(gap) or 10
    edge = edge or "auto"
    margin = tonumber(margin) or 8

    if qwen_native and qwen_native.compute_dock_position then
        return qwen_native.compute_dock_position(bx, by, bsize, pw, ph, gap, edge, sw, sh, margin)
    end

    local px, py
    if edge == "left" then
        px = bx + bsize + gap
        py = by + (bsize - ph) / 2
    elseif edge == "right" then
        px = bx - pw - gap
        py = by + (bsize - ph) / 2
    elseif edge == "top" then
        px = bx + (bsize - pw) / 2
        py = by + bsize + gap
    else
        px = bx + (bsize - pw) / 2
        py = by - ph - gap
    end
    px, py = utils.clamp_to_screen(px, py, pw, ph, margin)
    return px, py, edge
end

----------- Rounded rectangle path -----------------------------------
function utils.rounded_rect(cr, x, y, w, h, r)
    if not cr then return end
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    w = math.max(2, tonumber(w) or 2)
    h = math.max(2, tonumber(h) or 2)
    r = math.max(0, math.min(tonumber(r) or 6, w / 2, h / 2))
    local pi = math.pi
    cr:new_sub_path()
    cr:arc(x + w - r, y + r,     r, -pi/2, 0)
    cr:arc(x + w - r, y + h - r, r, 0,      pi/2)
    cr:arc(x + r,     y + h - r, r, pi/2,   pi)
    cr:arc(x + r,     y + r,     r, pi,     3*pi/2)
    cr:close_path()
end

----------- Set source from colour table {r,g,b,a} with fallback -----
function utils.set_colour(cr, c)
    if not cr then return end
    if type(c) ~= "table" then c = DEFAULT_COLOR end
    local r = tonumber(c[1]) or DEFAULT_COLOR[1]
    local g = tonumber(c[2]) or DEFAULT_COLOR[2]
    local b = tonumber(c[3]) or DEFAULT_COLOR[3]
    local a = tonumber(c[4]) or 1.0
    cr:set_source_rgba(r, g, b, a)
end

----------- Safe Pango Font Description with Fallback ----------------
local function safe_font(font_desc)
    local fstr = (type(font_desc) == "string" and #font_desc > 0) and font_desc or DEFAULT_FONT
    local ok, fd = pcall(Pango.FontDescription.from_string, fstr)
    if ok and fd then return fd end
    return Pango.FontDescription.from_string(DEFAULT_FONT)
end

----------- Draw text with Pango and return height -------------------
function utils.draw_text(cr, x, y, text, font_desc, colour, max_width)
    if not cr then return 0, 0 end
    local safe_str = tostring(text or "")
    cr:save()
    utils.set_colour(cr, colour)
    cr:move_to(tonumber(x) or 0, tonumber(y) or 0)
    local layout = PangoCairo.create_layout(cr)
    layout:set_text(safe_str, -1)
    layout:set_font_description(safe_font(font_desc))
    if max_width and tonumber(max_width) and tonumber(max_width) > 0 then
        layout:set_width(tonumber(max_width) * Pango.SCALE)
        layout:set_ellipsize(Pango.EllipsizeMode.END)
    end
    PangoCairo.show_layout(cr, layout)
    local _, logical = layout:get_pixel_extents()
    cr:restore()
    return logical.height, logical.width
end

----------- Draw multiline text with word wrap -----------------------
function utils.draw_text_wrap(cr, x, y, text, font_desc, colour, max_width)
    if not cr then return 0, 0 end
    local safe_str = tostring(text or "")
    cr:save()
    utils.set_colour(cr, colour)
    cr:move_to(tonumber(x) or 0, tonumber(y) or 0)
    local layout = PangoCairo.create_layout(cr)
    layout:set_text(safe_str, -1)
    layout:set_font_description(safe_font(font_desc))
    local mw = math.max(40, tonumber(max_width) or 200)
    layout:set_width(mw * Pango.SCALE)
    layout:set_wrap(Pango.WrapMode.WORD_CHAR)
    PangoCairo.show_layout(cr, layout)
    local _, logical = layout:get_pixel_extents()
    cr:restore()
    return logical.height, logical.width
end

----------- Load and cache a pixbuf with automatic fallback ----------
local pixbuf_cache = {}

function utils.load_pixbuf(path, size)
    if not path or type(path) ~= "string" then return nil end
    local s = tonumber(size) or 64
    local key = path .. "@" .. s
    if pixbuf_cache[key] then return pixbuf_cache[key] end
    local ok, pb = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale, path, s, s, true)
    if ok and pb then
        pixbuf_cache[key] = pb
        return pb
    end
    return nil
end

----------- Load state sprite from assets/sprites/ with fallback -----
function utils.load_sprite(state_name, size)
    local s = tonumber(size) or config.BUBBLE_SIZE or 72
    local st = tostring(state_name or "idle")
    local assets = config.ASSETS_DIR or (config.BASE_DIR .. "/assets")
    local candidates = {
        assets .. "/sprites/" .. st .. ".png",
        assets .. "/sprites/" .. st .. ".webp",
        assets .. "/sprites/idle.png",
        assets .. "/avatar.png",
        assets .. "/avatar.jpg",
        assets .. "/icon.png",
    }
    for _, p in ipairs(candidates) do
        local pb = utils.load_pixbuf(p, s)
        if pb then return pb end
    end
    return nil
end

----------- Draw circular avatar from pixbuf -------------------------
function utils.draw_avatar(cr, pixbuf, cx, cy, radius)
    if not cr or not pixbuf then return end
    cr:save()
    cr:arc(cx, cy, radius, 0, 2 * math.pi)
    cr:clip()
    local pw = math.max(1, pixbuf:get_width())
    local ph = math.max(1, pixbuf:get_height())
    local scale = (radius * 2) / math.min(pw, ph)
    cr:translate(cx - (pw * scale / 2), cy - (ph * scale / 2))
    cr:scale(scale, scale)
    Gdk.cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
    cr:paint()
    cr:restore()
end

----------- Draw circular avatar with accent ring --------------------
function utils.draw_avatar_ring(cr, pixbuf, cx, cy, radius)
    if not cr then return end
    cr:save()
    cr:arc(cx, cy, radius + 3, 0, 2 * math.pi)
    utils.set_colour(cr, config.ACCENT)
    cr:set_line_width(2.2)
    cr:stroke()
    cr:restore()
    utils.draw_avatar(cr, pixbuf, cx, cy, radius)
end

----------- Notification badge (geometric dot) -----------------------
function utils.draw_badge(cr, x, y, radius, colour)
    if not cr then return end
    cr:save()
    utils.set_colour(cr, colour)
    cr:arc(x, y, radius, 0, 2 * math.pi)
    cr:fill()
    cr:restore()
end

----------- Simple lerp for animations -------------------------------
function utils.lerp(a, b, t)
    return a + (b - a) * t
end

function utils.ease_out(t)
    return 1 - (1 - t) * (1 - t)
end

function utils.ease_in_out(t)
    if t < 0.5 then
        return 2 * t * t
    else
        return 1 - ((-2 * t + 2)^2) / 2
    end
end

function utils.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

return utils
