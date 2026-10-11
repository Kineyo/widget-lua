----------------------------------------------------------------------
-- player.lua  –  Floating YouTube Music Mini Player for Qwen-Widget
--                Inspired by ng2-youtube-player-mini and Linux MPRIS.
--                Displays Cover Art, Title, Artist, Seek Bar, and Controls.
----------------------------------------------------------------------
local lgi       = require("lgi")
local Gtk       = lgi.require("Gtk", "3.0")
local Gdk       = lgi.require("Gdk", "3.0")
local GLib      = lgi.GLib
local Pango     = lgi.Pango
local cairo     = lgi.cairo

local config    = require("config")
local utils     = require("utils")
local animator  = require("animator")
local mpris     = require("mpris")

local player = {}

-- UI Elements
player.window       = nil
player.visible      = false
player.pinned       = false
player.cover_area   = nil
player.title_label  = nil
player.artist_label = nil
player.play_btn     = nil
player.scale        = nil
player.pos_label    = nil
player.len_label    = nil
player.pin_btn      = nil

-- State
local hide_timer    = nil
local user_seeking  = false
local last_edge     = "right"
local last_bx, last_by = 0, 0
local last_bsize    = config.BUBBLE_SIZE

----------------------------------------------------------------------
-- CSS styling for Player Window
----------------------------------------------------------------------
local CSS = [[
.player-window {
    background-color: transparent;
}
.player-card {
    background-color: transparent;
    border-radius: 16px;
    padding: 10px 14px;
}
.player-header {
    color: #F472B6;
    font-family: "Sans";
    font-weight: bold;
    font-size: 10.5px;
}
.player-title {
    color: #FFFFFF;
    font-family: "Sans";
    font-weight: bold;
    font-size: 12px;
}
.player-artist {
    color: #CBD5E1;
    font-family: "Sans";
    font-size: 10.5px;
}
.player-time {
    color: #94A3B8;
    font-family: "Monospace";
    font-size: 9px;
}
.player-btn {
    background-color: rgba(45, 40, 72, 0.85);
    color: #E2E8F0;
    border: 1px solid rgba(139, 92, 246, 0.3);
    border-radius: 50%;
    min-width: 28px;
    min-height: 28px;
    padding: 0;
    font-size: 11px;
}
.player-btn:hover {
    background-color: rgba(139, 92, 246, 0.5);
    border-color: #F472B6;
    color: #FFFFFF;
}
.player-btn-main {
    background-color: #F472B6;
    color: #FFFFFF;
    border: none;
    border-radius: 50%;
    min-width: 32px;
    min-height: 32px;
    padding: 0;
    font-size: 13px;
    font-weight: bold;
}
.player-btn-main:hover {
    background-color: #EC4899;
}
.player-btn-small {
    background-color: transparent;
    color: #94A3B8;
    border: none;
    padding: 2px 4px;
    font-size: 11px;
}
.player-btn-small:hover {
    color: #F472B6;
}
.player-btn-pinned {
    color: #F472B6;
    font-weight: bold;
}
.player-scale trough {
    background-color: rgba(50, 45, 80, 0.7);
    border-radius: 3px;
    min-height: 4px;
}
.player-scale highlight {
    background-color: #F472B6;
    border-radius: 3px;
    min-height: 4px;
}
.player-scale slider {
    background-color: #FFFFFF;
    border-radius: 50%;
    min-width: 10px;
    min-height: 10px;
    margin: -3px;
}
.player-scale slider:hover {
    background-color: #F472B6;
}
]]

local css_applied = false
local function apply_css()
    if css_applied then return end
    css_applied = true
    local provider = Gtk.CssProvider()
    pcall(function()
        provider:load_from_data(CSS, #CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    end)
end

----------------------------------------------------------------------
-- Auto-dismiss timer management
----------------------------------------------------------------------
local function cancel_hide_timer()
    if hide_timer then
        pcall(function() GLib.source_remove(hide_timer) end)
        hide_timer = nil
    end
end

local function schedule_hide_timer()
    cancel_hide_timer()
    if player.pinned then return end

    hide_timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.PLAYER_AUTO_HIDE_MS or 12000, function()
        hide_timer = nil
        if not player.pinned and player.visible then
            player.hide()
        end
        return false
    end)
end

----------------------------------------------------------------------
-- Draw album cover with rounded corners
----------------------------------------------------------------------
local function draw_cover(widget, cr)
    local w = widget:get_allocated_width()
    local h = widget:get_allocated_height()
    local r = 8

    -- Rounded clipping mask
    cr:save()
    utils.rounded_rect(cr, 0, 0, w, h, r)
    cr:clip()

    local pb = mpris.track.art_pixbuf
    if pb then
        local pw = pb:get_width()
        local ph = pb:get_height()
        local scale = math.max(w / pw, h / ph)
        cr:translate((w - pw * scale) / 2, (h - ph * scale) / 2)
        cr:scale(scale, scale)
        Gdk.cairo_set_source_pixbuf(cr, pb, 0, 0)
        cr:paint()
    else
        -- Fallback: Cute musical gradient card
        local pat = cairo.Pattern.create_linear(0, 0, w, h)
        pat:add_color_stop_rgba(0, 0.45, 0.15, 0.55, 0.9)
        pat:add_color_stop_rgba(1, 0.15, 0.25, 0.45, 0.9)
        cr:set_source(pat)
        cr:paint()

        -- Stylized musical note
        utils.draw_text(cr, w / 2 - 8, h / 2 - 14, "🎵", "Sans 16", { 1, 1, 1, 0.8 }, w)
    end
    cr:restore()

    -- Subtle border
    cr:save()
    utils.rounded_rect(cr, 0.5, 0.5, w - 1, h - 1, r)
    cr:set_source_rgba(1, 0.41, 0.71, 0.4)
    cr:set_line_width(1.0)
    cr:stroke()
    cr:restore()

    return true
end

----------------------------------------------------------------------
-- Update track metadata in UI
----------------------------------------------------------------------
function player.update_ui()
    if not player.window then return end

    local track = mpris.track
    local title = (#track.title > 0) and track.title or "Sin reproducción"
    local artist = (#track.artist > 0) and track.artist or "YouTube Music"

    if player.title_label then
        player.title_label:set_text(title)
        player.title_label:set_tooltip_text(title)
    end

    if player.artist_label then
        player.artist_label:set_text(artist)
        player.artist_label:set_tooltip_text(artist)
    end

    if player.play_btn then
        player.play_btn:set_label(track.status == "Playing" and "⏸" or "▶")
    end

    if player.cover_area then
        player.cover_area:queue_draw()
    end

    -- Update scale length
    if player.scale and not user_seeking then
        local len = track.length > 0 and track.length or 100
        local pos = math.min(track.position, len)
        local adj = player.scale:get_adjustment()
        adj:set_upper(len)
        adj:set_value(pos)

        if player.pos_label then
            player.pos_label:set_text(mpris.format_time(pos))
        end
        if player.len_label then
            player.len_label:set_text(mpris.format_time(track.length))
        end
    end
end

----------------------------------------------------------------------
-- Build the Player Window
----------------------------------------------------------------------
function player.build()
    if player.window then return end
    apply_css()

    local win = Gtk.Window {
        type = Gtk.WindowType.POPUP,
        title = "YouTube Music Mini Player",
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = false,
        accept_focus = false,
        type_hint = Gdk.WindowTypeHint.DOCK,
        default_width  = config.PLAYER_W or 350,
        default_height = config.PLAYER_H or 138,
    }
    win:set_keep_above(true)
    win:set_app_paintable(true)
    win:get_style_context():add_class("player-window")

    -- RGBA
    local screen = win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then win:set_visual(visual) end

    -- Draw glassmorphic background
    win.on_draw = function(self, cr)
        local w = self:get_allocated_width()
        local h = self:get_allocated_height()
        local r = config.PLAYER_RADIUS or 16

        cr:set_operator(cairo.Operator.SOURCE)
        cr:set_source_rgba(0, 0, 0, 0)
        cr:paint()
        cr:set_operator(cairo.Operator.OVER)

        -- Soft diffused ambient shadow
        for k = 4, 1, -1 do
            cr:new_sub_path()
            utils.rounded_rect(cr, 1, 1 + k * 0.7, w - 2, h - 2, r)
            cr:set_source_rgba(0, 0, 0, 0.04 * (5 - k))
            cr:fill()
        end

        -- Dark glassy background
        utils.rounded_rect(cr, 1, 1, w - 2, h - 2, r)
        local bg_pat = cairo.Pattern.create_linear(0, 0, 0, h)
        bg_pat:add_color_stop_rgba(0, 0.075, 0.065, 0.125, 0.97)
        bg_pat:add_color_stop_rgba(1, 0.050, 0.045, 0.095, 0.97)
        cr:set_source(bg_pat)
        cr:fill_preserve()

        -- Minimalist hairline accent border
        cr:set_source_rgba(config.ACCENT_PINK[1], config.ACCENT_PINK[2], config.ACCENT_PINK[3], 0.35)
        cr:set_line_width(1.2)
        cr:stroke()

        return false
    end

    -- Container card
    local card = Gtk.Box {
        orientation = Gtk.Orientation.VERTICAL,
        spacing = 4,
        margin_start = 12, margin_end = 12,
        margin_top = 8, margin_bottom = 8,
    }

    -- 1) Header Row
    local header_box = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL, spacing = 6 }
    local brand = Gtk.Label { label = "🎵 YouTube Music" }
    brand:get_style_context():add_class("player-header")
    header_box:pack_start(brand, false, false, 0)

    header_box:pack_start(Gtk.Label { label = "" }, true, true, 0)

    -- Pin button
    local pin_btn = Gtk.Button { label = "📌" }
    pin_btn:get_style_context():add_class("player-btn-small")
    pin_btn:set_tooltip_text("Fijar reproductor (evitar auto-ocultar)")
    pin_btn.on_clicked = function()
        player.pinned = not player.pinned
        if player.pinned then
            pin_btn:get_style_context():add_class("player-btn-pinned")
            cancel_hide_timer()
        else
            pin_btn:get_style_context():remove_class("player-btn-pinned")
            schedule_hide_timer()
        end
    end
    header_box:pack_end(pin_btn, false, false, 0)
    player.pin_btn = pin_btn

    -- Close button
    local close_btn = Gtk.Button { label = "✕" }
    close_btn:get_style_context():add_class("player-btn-small")
    close_btn:set_tooltip_text("Cerrar")
    close_btn.on_clicked = function() player.hide() end
    header_box:pack_end(close_btn, false, false, 0)

    card:pack_start(header_box, false, false, 0)

    -- 2) Middle Content Row (Cover Art + Info + Buttons)
    local mid_box = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL, spacing = 10 }

    -- Album cover drawing area
    local cover_size = config.PLAYER_COVER_SIZE or 68
    local cover_area = Gtk.DrawingArea {
        width_request = cover_size,
        height_request = cover_size,
    }
    cover_area.on_draw = draw_cover
    mid_box:pack_start(cover_area, false, false, 0)
    player.cover_area = cover_area

    -- Info and controls vertical box
    local info_box = Gtk.Box { orientation = Gtk.Orientation.VERTICAL, spacing = 2 }

    local title_lbl = Gtk.Label {
        label = "Sin reproducción",
        xalign = 0,
        ellipsize = Pango.EllipsizeMode.END,
    }
    title_lbl:get_style_context():add_class("player-title")
    info_box:pack_start(title_lbl, false, false, 0)
    player.title_label = title_lbl

    local artist_lbl = Gtk.Label {
        label = "YouTube Music",
        xalign = 0,
        ellipsize = Pango.EllipsizeMode.END,
    }
    artist_lbl:get_style_context():add_class("player-artist")
    info_box:pack_start(artist_lbl, false, false, 0)
    player.artist_label = artist_lbl

    -- Controls row (Prev, Play/Pause, Next)
    local ctrl_box = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL,
        spacing = 8,
        margin_top = 4,
    }

    local prev_btn = Gtk.Button { label = "⏮" }
    prev_btn:get_style_context():add_class("player-btn")
    prev_btn:set_tooltip_text("Canción anterior")
    prev_btn.on_clicked = function() mpris.previous() end
    ctrl_box:pack_start(prev_btn, false, false, 0)

    local play_btn = Gtk.Button { label = "▶" }
    play_btn:get_style_context():add_class("player-btn-main")
    play_btn:set_tooltip_text("Reproducir / Pausar")
    play_btn.on_clicked = function() mpris.play_pause() end
    ctrl_box:pack_start(play_btn, false, false, 0)
    player.play_btn = play_btn

    local next_btn = Gtk.Button { label = "⏭" }
    next_btn:get_style_context():add_class("player-btn")
    next_btn:set_tooltip_text("Siguiente canción")
    next_btn.on_clicked = function() mpris.next() end
    ctrl_box:pack_start(next_btn, false, false, 0)

    info_box:pack_start(ctrl_box, false, false, 0)
    mid_box:pack_start(info_box, true, true, 0)

    card:pack_start(mid_box, true, true, 0)

    -- 3) Bottom Seek Row (Time, Scale, Duration)
    local seek_box = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL,
        spacing = 6,
        margin_top = 2,
    }

    local pos_lbl = Gtk.Label { label = "00:00" }
    pos_lbl:get_style_context():add_class("player-time")
    seek_box:pack_start(pos_lbl, false, false, 0)
    player.pos_label = pos_lbl

    local adj = Gtk.Adjustment {
        lower = 0,
        upper = 100,
        value = 0,
        step_increment = 1,
        page_increment = 10,
    }
    local scale = Gtk.Scale {
        orientation = Gtk.Orientation.HORIZONTAL,
        adjustment = adj,
        draw_value = false,
    }
    scale:get_style_context():add_class("player-scale")

    -- Drag / Seek interaction
    scale.on_button_press_event = function()
        user_seeking = true
        return false
    end

    scale.on_button_release_event = function(self, event)
        local val = scale:get_value()
        mpris.seek(val)
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 350, function()
            user_seeking = false
            return false
        end)
        return false
    end

    scale.on_change_value = function(self, scroll_type, new_val)
        if user_seeking and player.pos_label then
            player.pos_label:set_text(mpris.format_time(new_val))
        end
        return false
    end

    seek_box:pack_start(scale, true, true, 0)
    player.scale = scale

    local len_lbl = Gtk.Label { label = "00:00" }
    len_lbl:get_style_context():add_class("player-time")
    seek_box:pack_start(len_lbl, false, false, 0)
    player.len_label = len_lbl

    card:pack_start(seek_box, false, false, 0)

    win:add(card)

    -- Mouse Hover pauses auto-dismiss
    win:add_events(Gdk.EventMask.ENTER_NOTIFY_MASK + Gdk.EventMask.LEAVE_NOTIFY_MASK)
    win.on_enter_notify_event = function()
        cancel_hide_timer()
        return false
    end
    win.on_leave_notify_event = function()
        if not player.pinned then
            schedule_hide_timer()
        end
        return false
    end

    player.window = win

    -- Connect MPRIS events (update player UI if player is open, do NOT auto-deploy)
    mpris.add_track_listener(function(track)
        player.update_ui()
    end)

    mpris.on_status_change = function(status)
        player.update_ui()
    end

    mpris.on_position_tick = function(pos, len)
        if not player.visible or user_seeking then return end
        if player.scale then
            local adj_scale = player.scale:get_adjustment()
            if len > 0 then adj_scale:set_upper(len) end
            adj_scale:set_value(pos)
        end
        if player.pos_label then
            player.pos_label:set_text(mpris.format_time(pos))
        end
        if player.len_label and len > 0 then
            player.len_label:set_text(mpris.format_time(len))
        end
    end

    mpris.on_art_loaded = function(pb)
        if player.cover_area then
            player.cover_area:queue_draw()
        end
    end
end

----------------------------------------------------------------------
-- Show Player positioned relative to circular bubble
----------------------------------------------------------------------
function player.show(bx, by, bsize, edge)
    player.build()
    if not player.window then return end

    player.visible = true

    last_bx = bx or last_bx
    last_by = by or last_by
    last_bsize = bsize or last_bsize
    last_edge = edge or last_edge

    local screen = Gdk.Screen.get_default()
    local sw = screen:get_width()
    local sh = screen:get_height()

    local pw = config.PLAYER_W or 350
    local ph = config.PLAYER_H or 138
    local gap = config.PLAYER_GAP or 10

    local px, py
    if last_edge == "left" then
        px = last_bx + last_bsize + gap
        py = last_by + (last_bsize - ph) / 2
    elseif last_edge == "right" then
        px = last_bx - pw - gap
        py = last_by + (last_bsize - ph) / 2
    elseif last_edge == "top" then
        px = last_bx + (last_bsize - pw) / 2
        py = last_by + last_bsize + gap
    else -- bottom
        px = last_bx + (last_bsize - pw) / 2
        py = last_by - ph - gap
    end

    -- Clamp within screen bounds
    px = math.max(6, math.min(px, sw - pw - 6))
    py = math.max(6, math.min(py, sh - ph - 6))

    player.update_ui()
    player.window:move(math.floor(px), math.floor(py))
    if not player.window:get_visible() then
        player.window:set_opacity(0)
        player.window:show_all()
    end

    animator.fade(player.window, "in", function()
        schedule_hide_timer()
    end)
end

----------------------------------------------------------------------
-- Hide Player
----------------------------------------------------------------------
function player.hide()
    cancel_hide_timer()
    if not player.window then return end
    player.visible = false

    animator.fade(player.window, "out", function()
        if not player.visible and player.window then
            player.window:hide()
            player.window:set_opacity(0)
        end
    end)
end

----------------------------------------------------------------------
-- Toggle Player
----------------------------------------------------------------------
function player.toggle(bx, by, bsize, edge)
    if player.visible then
        player.hide()
    else
        player.show(bx, by, bsize, edge)
    end
end

return player
