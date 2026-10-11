----------------------------------------------------------------------
-- utils.lua  –  Cairo / Pango drawing helpers for Qwen-Widget
----------------------------------------------------------------------
local lgi    = require("lgi")
local cairo  = lgi.cairo
local Pango  = lgi.Pango
local PangoCairo = lgi.PangoCairo
local GdkPixbuf  = lgi.GdkPixbuf
local Gdk    = lgi.require("Gdk", "3.0")

local config = require("config")
local utils  = {}

----------- Rounded rectangle path -----------------------------------
function utils.rounded_rect(cr, x, y, w, h, r)
    local pi = math.pi
    cr:new_sub_path()
    cr:arc(x + w - r, y + r,     r, -pi/2, 0)
    cr:arc(x + w - r, y + h - r, r, 0,      pi/2)
    cr:arc(x + r,     y + h - r, r, pi/2,   pi)
    cr:arc(x + r,     y + r,     r, pi,     3*pi/2)
    cr:close_path()
end

----------- Set source from colour table  {r,g,b,a} -----------------
function utils.set_colour(cr, c)
    cr:set_source_rgba(c[1], c[2], c[3], c[4] or 1)
end

----------- Draw text with Pango and return height -------------------
function utils.draw_text(cr, x, y, text, font_desc, colour, max_width)
    cr:save()
    utils.set_colour(cr, colour)
    cr:move_to(x, y)
    local layout = PangoCairo.create_layout(cr)
    layout:set_text(text, -1)
    layout:set_font_description(Pango.FontDescription.from_string(font_desc))
    if max_width then
        layout:set_width(max_width * Pango.SCALE)
        layout:set_ellipsize(Pango.EllipsizeMode.END)
    end
    PangoCairo.show_layout(cr, layout)
    local _, logical = layout:get_pixel_extents()
    cr:restore()
    return logical.height, logical.width
end

----------- Draw multiline text with word wrap -----------------------
function utils.draw_text_wrap(cr, x, y, text, font_desc, colour, max_width)
    cr:save()
    utils.set_colour(cr, colour)
    cr:move_to(x, y)
    local layout = PangoCairo.create_layout(cr)
    layout:set_text(text, -1)
    layout:set_font_description(Pango.FontDescription.from_string(font_desc))
    layout:set_width(max_width * Pango.SCALE)
    layout:set_wrap(Pango.WrapMode.WORD_CHAR)
    PangoCairo.show_layout(cr, layout)
    local _, logical = layout:get_pixel_extents()
    cr:restore()
    return logical.height, logical.width
end

----------- Load and cache a pixbuf ----------------------------------
local pixbuf_cache = {}

function utils.load_pixbuf(path, size)
    local key = path .. "@" .. (size or 0)
    if pixbuf_cache[key] then return pixbuf_cache[key] end
    local ok, pb = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale,
                         path, size or -1, size or -1, true)
    if ok and pb then
        pixbuf_cache[key] = pb
        return pb
    end
    return nil
end

----------- Draw circular avatar from pixbuf -------------------------
function utils.draw_avatar(cr, pixbuf, cx, cy, radius)
    if not pixbuf then return end
    cr:save()
    -- Clip to circle
    cr:arc(cx, cy, radius, 0, 2 * math.pi)
    cr:clip()
    -- Scale pixbuf to fit
    local pw = pixbuf:get_width()
    local ph = pixbuf:get_height()
    local scale = (radius * 2) / math.min(pw, ph)
    cr:translate(cx - (pw * scale / 2), cy - (ph * scale / 2))
    cr:scale(scale, scale)
    lgi.Gdk.cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
    cr:paint()
    cr:restore()
end

----------- Draw circular avatar with purple glow ring ---------------
function utils.draw_avatar_ring(cr, pixbuf, cx, cy, radius)
    -- Outer glow ring
    cr:save()
    cr:arc(cx, cy, radius + 3, 0, 2 * math.pi)
    utils.set_colour(cr, config.ACCENT)
    cr:set_line_width(2.5)
    cr:stroke()
    cr:restore()
    -- Avatar
    utils.draw_avatar(cr, pixbuf, cx, cy, radius)
end

----------- Notification badge (small dot) ---------------------------
function utils.draw_badge(cr, x, y, radius, colour)
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

----------- Ease-out quad for smooth animations ----------------------
function utils.ease_out(t)
    return 1 - (1 - t) * (1 - t)
end

----------- Ease-in-out for expansion --------------------------------
function utils.ease_in_out(t)
    if t < 0.5 then
        return 2 * t * t
    else
        return 1 - ((-2 * t + 2)^2) / 2
    end
end

----------- Clamp value between min and max --------------------------
function utils.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

return utils
