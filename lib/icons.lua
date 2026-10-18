-- ============================================================================
-- lib/icons.lua - Vector Icon Renderer (Cairo) & Asset Loader (Zero Emojis)
-- Provides clean geometric icons and safe GdkPixbuf/Gtk.DrawingArea fallbacks
-- ============================================================================

local lgi   = require("lgi")
local Gtk   = lgi.require("Gtk", "3.0")
local Gdk   = lgi.require("Gdk", "3.0")
local GdkPixbuf = lgi.require("GdkPixbuf", "2.0")
local cairo = lgi.cairo

local M = {}

local BASE_DIR = (debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./") .. "../"

local COLORS = {
    primary = { 0.35, 0.65, 1.00, 1.0 },
    accent  = { 0.45, 0.85, 0.65, 1.0 },
    fg      = { 0.92, 0.94, 0.98, 1.0 },
    muted   = { 0.62, 0.66, 0.75, 1.0 },
    danger  = { 0.95, 0.38, 0.42, 1.0 },
    warning = { 0.96, 0.76, 0.32, 1.0 },
}

-- Draw geometric vector icon on a Cairo context inside [0..w, 0..h]
function M.draw(cr, name, w, h, rgba)
    local c = rgba or COLORS.fg
    cr:save()
    cr:set_source_rgba(c[1], c[2], c[3], c[4] or 1.0)
    cr:set_line_width(math.max(1.5, math.min(w, h) * 0.10))
    cr:set_line_cap(cairo.LineCap.ROUND)
    cr:set_line_join(cairo.LineJoin.ROUND)

    local cx, cy = w * 0.5, h * 0.5
    local r = math.min(w, h) * 0.34

    if name == "play" then
        cr:move_to(cx - r * 0.6, cy - r * 0.85)
        cr:line_to(cx + r * 0.9, cy)
        cr:line_to(cx - r * 0.6, cy + r * 0.85)
        cr:close_path()
        cr:fill()
    elseif name == "pause" then
        local bw = r * 0.42
        local bh = r * 1.6
        cr:rectangle(cx - r * 0.65, cy - bh * 0.5, bw, bh)
        cr:rectangle(cx + r * 0.23, cy - bh * 0.5, bw, bh)
        cr:fill()
    elseif name == "prev" then
        cr:rectangle(cx - r * 0.85, cy - r * 0.8, r * 0.22, r * 1.6)
        cr:fill()
        cr:move_to(cx + r * 0.75, cy - r * 0.8)
        cr:line_to(cx - r * 0.35, cy)
        cr:line_to(cx + r * 0.75, cy + r * 0.8)
        cr:close_path()
        cr:fill()
    elseif name == "next" then
        cr:move_to(cx - r * 0.75, cy - r * 0.8)
        cr:line_to(cx + r * 0.35, cy)
        cr:line_to(cx - r * 0.75, cy + r * 0.8)
        cr:close_path()
        cr:fill()
        cr:rectangle(cx + r * 0.60, cy - r * 0.8, r * 0.22, r * 1.6)
        cr:fill()
    elseif name == "volume" then
        cr:move_to(cx - r * 0.85, cy - r * 0.35)
        cr:line_to(cx - r * 0.40, cy - r * 0.35)
        cr:line_to(cx + r * 0.05, cy - r * 0.80)
        cr:line_to(cx + r * 0.05, cy + r * 0.80)
        cr:line_to(cx - r * 0.40, cy + r * 0.35)
        cr:line_to(cx - r * 0.85, cy + r * 0.35)
        cr:close_path()
        cr:fill()
        cr:arc(cx + r * 0.15, cy, r * 0.55, -0.7, 0.7)
        cr:stroke()
    elseif name == "close" then
        cr:move_to(cx - r * 0.7, cy - r * 0.7)
        cr:line_to(cx + r * 0.7, cy + r * 0.7)
        cr:move_to(cx + r * 0.7, cy - r * 0.7)
        cr:line_to(cx - r * 0.7, cy + r * 0.7)
        cr:stroke()
    elseif name == "settings" then
        cr:arc(cx, cy, r * 0.48, 0, math.pi * 2)
        cr:stroke()
        for i = 0, 7 do
            local a = i * (math.pi / 4)
            cr:move_to(cx + math.cos(a) * r * 0.62, cy + math.sin(a) * r * 0.62)
            cr:line_to(cx + math.cos(a) * r * 0.95, cy + math.sin(a) * r * 0.95)
        end
        cr:stroke()
    elseif name == "chat" then
        cr:arc(cx, cy - r * 0.1, r * 0.85, 0, math.pi * 2)
        cr:stroke()
        cr:arc(cx - r * 0.35, cy - r * 0.1, r * 0.12, 0, math.pi * 2)
        cr:arc(cx,            cy - r * 0.1, r * 0.12, 0, math.pi * 2)
        cr:arc(cx + r * 0.35, cy - r * 0.1, r * 0.12, 0, math.pi * 2)
        cr:fill()
    elseif name == "music" then
        cr:move_to(cx - r * 0.35, cy + r * 0.55)
        cr:line_to(cx - r * 0.35, cy - r * 0.75)
        cr:line_to(cx + r * 0.65, cy - r * 0.95)
        cr:line_to(cx + r * 0.65, cy + r * 0.35)
        cr:stroke()
        cr:arc(cx - r * 0.55, cy + r * 0.55, r * 0.28, 0, math.pi * 2)
        cr:arc(cx + r * 0.45, cy + r * 0.35, r * 0.28, 0, math.pi * 2)
        cr:fill()
    elseif name == "grammar" or name == "check" then
        cr:move_to(cx - r * 0.75, cy + r * 0.05)
        cr:line_to(cx - r * 0.20, cy + r * 0.65)
        cr:line_to(cx + r * 0.85, cy - r * 0.60)
        cr:stroke()
    elseif name == "cloud" then
        cr:arc(cx - r * 0.25, cy + r * 0.10, r * 0.48, math.pi * 0.5, math.pi * 1.6)
        cr:arc(cx + r * 0.20, cy - r * 0.10, r * 0.52, math.pi * 1.1, math.pi * 0.2)
        cr:close_path()
        cr:stroke()
    elseif name == "cpu" or name == "local" then
        cr:rectangle(cx - r * 0.6, cy - r * 0.6, r * 1.2, r * 1.2)
        cr:stroke()
        cr:rectangle(cx - r * 0.25, cy - r * 0.25, r * 0.5, r * 0.5)
        cr:fill()
    elseif name == "send" then
        cr:move_to(cx - r * 0.8, cy - r * 0.7)
        cr:line_to(cx + r * 0.85, cy)
        cr:line_to(cx - r * 0.8, cy + r * 0.7)
        cr:line_to(cx - r * 0.45, cy)
        cr:close_path()
        cr:fill()
    else
        cr:arc(cx, cy, r * 0.5, 0, math.pi * 2)
        cr:fill()
    end

    cr:restore()
end

-- Create a Gtk.DrawingArea widget that renders a geometric vector icon
function M.widget(name, size, rgba)
    local s = size or 16
    local area = Gtk.DrawingArea {
        width_request  = s,
        height_request = s,
        valign         = Gtk.Align.CENTER,
        halign         = Gtk.Align.CENTER,
    }
    area.on_draw = function(_, cr)
        M.draw(cr, name, s, s, rgba)
        return true
    end
    return area
end

-- Load a sprite or icon GdkPixbuf with guaranteed fallback (never returns nil)
function M.load_pixbuf(rel_path, size)
    local s = size or 64
    local full_path = rel_path
    if not rel_path:match("^/") then
        full_path = BASE_DIR .. rel_path
    end
    local ok, pb = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale, full_path, s, s, true)
    if ok and pb then
        return pb
    end
    -- Fallback to avatar.png if a specific sprite fails
    local ok2, pb2 = pcall(GdkPixbuf.Pixbuf.new_from_file_at_scale, BASE_DIR .. "assets/avatar.png", s, s, true)
    if ok2 and pb2 then
        return pb2
    end
    -- Ultimate in-memory fallback surface converted to Pixbuf
    local surf = cairo.ImageSurface.create(cairo.Format.ARGB32, s, s)
    local cr = cairo.Context.create(surf)
    cr:arc(s * 0.5, s * 0.5, s * 0.45, 0, math.pi * 2)
    cr:set_source_rgba(0.18, 0.24, 0.36, 1.0)
    cr:fill()
    M.draw(cr, "cpu", s, s, COLORS.primary)
    return Gdk.pixbuf_get_from_surface(surf, 0, 0, s, s)
end

return M
