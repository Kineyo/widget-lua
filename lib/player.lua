----------------------------------------------------------------------
-- player.lua  –  Integrated Mini-Player for YouTube Music & Spotify
--                Zero emojis, geometric vector icons, real-time bubble
--                coordinate tracking, volume control & lyrics offset.
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
local lyrics    = require("lyrics")
local icons     = require("icons")

local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local player = {}

player.window       = nil
player.visible      = false
player.pinned       = false
player.cover_area   = nil
player.brand_label  = nil
player.title_label  = nil
player.artist_label = nil
player.play_btn     = nil
player.play_icon    = nil
player.scale        = nil
player.vol_scale    = nil
player.pos_label    = nil
player.len_label    = nil
player.pin_btn      = nil
player.lyr_btn      = nil
player.offset_label = nil
player.src_btns     = {}

local hide_timer    = nil
local user_seeking  = false
local user_vol      = false
local last_edge     = "right"
local last_bx, last_by = 0, 0
local last_bsize    = config.BUBBLE_SIZE or 72
local cur_px, cur_py = nil, nil

local CSS = [[
.player-window {
    background-color: transparent;
}
.player-header {
    color: #EC5DA3;
    font-family: "Sans";
    font-weight: bold;
    font-size: 10.5px;
}
.player-title {
    color: #F8FAFC;
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
    font-size: 9.5px;
}
.player-btn {
    background-color: #1A1E30;
    background-image: none;
    color: #F8FAFC;
    border: 1px solid #334155;
    border-radius: 8px;
    min-width: 30px;
    min-height: 26px;
    padding: 2px 8px;
    font-size: 10px;
    font-weight: 600;
}
.player-btn:hover {
    background-color: #F8FAFC;
    background-image: none;
    color: #090A10;
    border-color: #FFFFFF;
}
.player-btn-main {
    background-color: #EC5DA3;
    background-image: none;
    color: #FFFFFF;
    border: 1px solid #F472B6;
    border-radius: 8px;
    min-width: 44px;
    min-height: 26px;
    padding: 2px 10px;
    font-size: 10.5px;
    font-weight: bold;
}
.player-btn-main:hover {
    background-color: #F8FAFC;
    background-image: none;
    color: #090A10;
    border-color: #FFFFFF;
}
.player-pill {
    background-color: #151828;
    background-image: none;
    color: #94A3B8;
    border: 1px solid #283048;
    border-radius: 6px;
    padding: 1px 6px;
    font-size: 9px;
    font-weight: 600;
}
.player-pill:hover {
    background-color: #F8FAFC;
    background-image: none;
    color: #090A10;
}
.player-pill-active {
    background-color: #3B82F6;
    background-image: none;
    color: #FFFFFF;
    border: 1px solid #60A5FA;
    border-radius: 6px;
    padding: 1px 6px;
    font-size: 9px;
    font-weight: bold;
}
.player-scale trough {
    background-color: #1E243B;
    border-radius: 3px;
    min-height: 4px;
}
.player-scale highlight {
    background-color: #EC5DA3;
    border-radius: 3px;
    min-height: 4px;
}
.player-scale slider {
    background-color: #F8FAFC;
    border-radius: 50%;
    min-width: 10px;
    min-height: 10px;
    margin: -3px;
}
.player-vol-scale trough {
    background-color: #1E243B;
    border-radius: 3px;
    min-height: 4px;
}
.player-vol-scale highlight {
    background-color: #3B82F6;
    border-radius: 3px;
    min-height: 4px;
}
.player-vol-scale slider {
    background-color: #F8FAFC;
    border-radius: 50%;
    min-width: 8px;
    min-height: 8px;
    margin: -2px;
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

local function cancel_hide_timer()
    if hide_timer then
        pcall(function() GLib.source_remove(hide_timer) end)
        hide_timer = nil
    end
end

local function schedule_hide_timer()
    cancel_hide_timer()
    if player.pinned then return end

    hide_timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.PLAYER_AUTO_HIDE_MS or 14000, function()
        hide_timer = nil
        if not player.pinned and player.visible then
            player.hide()
        end
        return false
    end)
end

local function draw_cover(widget, cr)
    local w = widget:get_allocated_width()
    local h = widget:get_allocated_height()
    local r = 8

    cr:save()
    utils.rounded_rect(cr, 0, 0, w, h, r)
    cr:clip()

    local pb = mpris.track.art_pixbuf
    if pb then
        local pw = math.max(1, pb:get_width())
        local ph = math.max(1, pb:get_height())
        local scale = math.max(w / pw, h / ph)
        cr:translate((w - pw * scale) / 2, (h - ph * scale) / 2)
        cr:scale(scale, scale)
        Gdk.cairo_set_source_pixbuf(cr, pb, 0, 0)
        cr:paint()
    else
        local pat = cairo.Pattern.create_linear(0, 0, w, h)
        pat:add_color_stop_rgba(0, 0.14, 0.18, 0.32, 0.96)
        pat:add_color_stop_rgba(1, 0.08, 0.10, 0.20, 0.96)
        cr:set_source(pat)
        cr:paint()
        icons.draw(cr, "music", w, h, { 0.925, 0.365, 0.640, 0.9 })
    end
    cr:restore()

    cr:save()
    utils.rounded_rect(cr, 0.5, 0.5, w - 1, h - 1, r)
    cr:set_source_rgba(0.925, 0.365, 0.640, 0.45)
    cr:set_line_width(1.0)
    cr:stroke()
    cr:restore()

    return true
end

local function update_source_pills()
    local cur = config.music_source or "auto"
    for k, b in pairs(player.src_btns) do
        local ctx = b:get_style_context()
        ctx:remove_class("player-pill")
        ctx:remove_class("player-pill-active")
        if k == cur then
            ctx:add_class("player-pill-active")
        else
            ctx:add_class("player-pill")
        end
    end
end

function player.update_ui()
    if not player.window then return end

    local track = mpris.track
    local title = (#track.title > 0) and track.title or "Sin reproduccion activa"
    local artist = (#track.artist > 0) and track.artist or (track.player_name or "Reproductor")

    if player.brand_label then
        local src_name = (track.source == "spotify") and "SPOTIFY" or "YOUTUBE MUSIC"
        player.brand_label:set_text(src_name)
    end

    if player.title_label then
        player.title_label:set_text(title)
        player.title_label:set_tooltip_text(title)
    end

    if player.artist_label then
        player.artist_label:set_text(artist)
        player.artist_label:set_tooltip_text(artist)
    end

    if player.play_btn then
        player.play_btn:set_label(track.status == "Playing" and "PAUSA" or "PLAY")
    end

    if player.lyr_btn then
        local lyr_on = (config.skills and config.skills.lyrics ~= false)
        player.lyr_btn:set_label(lyr_on and "LETRAS: ON" or "LETRAS: OFF")
        local ctx = player.lyr_btn:get_style_context()
        ctx:remove_class("player-pill")
        ctx:remove_class("player-pill-active")
        ctx:add_class(lyr_on and "player-pill-active" or "player-pill")
    end

    if player.offset_label then
        local off_s = (tonumber(config.lyrics_offset_ms) or 0) / 1000.0
        player.offset_label:set_text(string.format("%+.1fs", off_s))
    end

    update_source_pills()

    if player.cover_area then
        player.cover_area:queue_draw()
    end

    if player.scale and not user_seeking then
        local len = track.length > 0 and track.length or 100
        local pos = math.min(track.position or 0, len)
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

    if player.vol_scale and not user_vol then
        local v = math.max(0, math.min(100, math.floor((track.volume or 1.0) * 100)))
        player.vol_scale:get_adjustment():set_value(v)
    end
end

function player.build()
    if player.window then return end
    apply_css()

    local win = Gtk.Window {
        type = Gtk.WindowType.POPUP,
        title = "Qwen Media Mini Player",
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = false,
        accept_focus = false,
        type_hint = Gdk.WindowTypeHint.DOCK,
        default_width  = config.PLAYER_W or 372,
        default_height = config.PLAYER_H or 192,
    }
    win:set_keep_above(true)
    win:set_app_paintable(true)
    win:get_style_context():add_class("player-window")

    local screen = win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then win:set_visual(visual) end

    win.on_draw = function(self, cr)
        local w = self:get_allocated_width()
        local h = self:get_allocated_height()
        local r = config.PLAYER_RADIUS or 15

        cr:set_operator(cairo.Operator.SOURCE)
        cr:set_source_rgba(0, 0, 0, 0)
        cr:paint()
        cr:set_operator(cairo.Operator.OVER)

        for k = 3, 1, -1 do
            cr:new_sub_path()
            utils.rounded_rect(cr, 1, 1 + k * 0.7, w - 2, h - 2, r)
            cr:set_source_rgba(0, 0, 0, 0.05 * (4 - k))
            cr:fill()
        end

        utils.rounded_rect(cr, 1, 1, w - 2, h - 2, r)
        local bg_pat = cairo.Pattern.create_linear(0, 0, 0, h)
        bg_pat:add_color_stop_rgba(0, 0.075, 0.082, 0.135, 0.98)
        bg_pat:add_color_stop_rgba(1, 0.050, 0.055, 0.095, 0.98)
        cr:set_source(bg_pat)
        cr:fill_preserve()

        cr:set_source_rgba(config.ACCENT_PINK[1], config.ACCENT_PINK[2], config.ACCENT_PINK[3], 0.45)
        cr:set_line_width(1.2)
        cr:stroke()
        return false
    end

    local card = Gtk.Box {
        orientation = Gtk.Orientation.VERTICAL,
        spacing = 5,
        margin_start = 12, margin_end = 12,
        margin_top = 8, margin_bottom = 8,
    }

    -- 1) Header Row: Brand + Source Selector (Auto | YT Music | Spotify) + Pin + Close
    local header_box = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL, spacing = 4 }
    local brand = Gtk.Label { label = "YOUTUBE MUSIC" }
    brand:get_style_context():add_class("player-header")
    header_box:pack_start(brand, false, false, 0)
    player.brand_label = brand

    header_box:pack_start(Gtk.Label { label = "" }, true, true, 0)

    local sources = {
        { id = "auto",    label = "Auto" },
        { id = "ytmusic", label = "YT Music" },
        { id = "spotify", label = "Spotify" },
    }
    for _, s in ipairs(sources) do
        local b = Gtk.Button { label = s.label }
        b:get_style_context():add_class("player-pill")
        b.on_clicked = function()
            mpris.set_source(s.id)
            player.update_ui()
        end
        player.src_btns[s.id] = b
        header_box:pack_start(b, false, false, 0)
    end

    local pin_btn = Gtk.Button { label = "FIJAR" }
    pin_btn:get_style_context():add_class("player-pill")
    pin_btn:set_tooltip_text("Mantener reproductor visible")
    pin_btn.on_clicked = function()
        player.pinned = not player.pinned
        local ctx = pin_btn:get_style_context()
        ctx:remove_class("player-pill")
        ctx:remove_class("player-pill-active")
        if player.pinned then
            ctx:add_class("player-pill-active")
            cancel_hide_timer()
        else
            ctx:add_class("player-pill")
            schedule_hide_timer()
        end
    end
    header_box:pack_start(pin_btn, false, false, 2)
    player.pin_btn = pin_btn

    local close_btn = Gtk.Button { label = "X" }
    close_btn:get_style_context():add_class("player-pill")
    close_btn:set_tooltip_text("Cerrar reproductor")
    close_btn.on_clicked = function() player.hide() end
    header_box:pack_end(close_btn, false, false, 0)

    card:pack_start(header_box, false, false, 0)

    -- 2) Middle Row: Cover Art + Metadata + Transport Controls
    local mid_box = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL, spacing = 10 }

    local cover_size = config.PLAYER_COVER_SIZE or 68
    local cover_area = Gtk.DrawingArea {
        width_request  = cover_size,
        height_request = cover_size,
    }
    cover_area.on_draw = draw_cover
    mid_box:pack_start(cover_area, false, false, 0)
    player.cover_area = cover_area

    local info_box = Gtk.Box { orientation = Gtk.Orientation.VERTICAL, spacing = 2 }

    local title_lbl = Gtk.Label {
        label     = "Sin reproduccion activa",
        xalign    = 0,
        ellipsize = Pango.EllipsizeMode.END,
    }
    title_lbl:get_style_context():add_class("player-title")
    info_box:pack_start(title_lbl, false, false, 0)
    player.title_label = title_lbl

    local artist_lbl = Gtk.Label {
        label     = "Reproductor Multimedia",
        xalign    = 0,
        ellipsize = Pango.EllipsizeMode.END,
    }
    artist_lbl:get_style_context():add_class("player-artist")
    info_box:pack_start(artist_lbl, false, false, 0)
    player.artist_label = artist_lbl

    -- Transport Controls (Prev, Play/Pause, Next + Volume)
    local ctrl_box = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL,
        spacing     = 6,
        margin_top  = 4,
    }

    local prev_btn = Gtk.Button { label = "ANT" }
    prev_btn:get_style_context():add_class("player-btn")
    prev_btn:set_tooltip_text("Pista anterior")
    prev_btn.on_clicked = function() mpris.previous() end
    ctrl_box:pack_start(prev_btn, false, false, 0)

    local play_btn = Gtk.Button { label = "PLAY" }
    play_btn:get_style_context():add_class("player-btn-main")
    play_btn:set_tooltip_text("Reproducir / Pausar")
    play_btn.on_clicked = function() mpris.play_pause() end
    ctrl_box:pack_start(play_btn, false, false, 0)
    player.play_btn = play_btn

    local next_btn = Gtk.Button { label = "SIG" }
    next_btn:get_style_context():add_class("player-btn")
    next_btn:set_tooltip_text("Siguiente pista")
    next_btn.on_clicked = function() mpris.next() end
    ctrl_box:pack_start(next_btn, false, false, 0)

    -- Volume slider
    local vol_lbl = Gtk.Label { label = "VOL" }
    vol_lbl:get_style_context():add_class("player-time")
    ctrl_box:pack_start(vol_lbl, false, false, 2)

    local vol_adj = Gtk.Adjustment {
        lower = 0, upper = 100, value = 100,
        step_increment = 2, page_increment = 10,
    }
    local vol_scale = Gtk.Scale {
        orientation = Gtk.Orientation.HORIZONTAL,
        adjustment  = vol_adj,
        draw_value  = false,
        width_request = 72,
    }
    vol_scale:get_style_context():add_class("player-vol-scale")
    vol_scale.on_button_press_event = function()
        user_vol = true
        return false
    end
    vol_scale.on_button_release_event = function()
        local v = vol_scale:get_value() / 100.0
        mpris.set_volume(v)
        user_vol = false
        return false
    end
    vol_scale.on_value_changed = function()
        if user_vol then
            mpris.set_volume(vol_scale:get_value() / 100.0)
        end
    end
    ctrl_box:pack_start(vol_scale, true, true, 0)
    player.vol_scale = vol_scale

    info_box:pack_start(ctrl_box, false, false, 0)
    mid_box:pack_start(info_box, true, true, 0)
    card:pack_start(mid_box, true, true, 0)

    -- 3) Seek Bar Row
    local seek_box = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL,
        spacing     = 6,
        margin_top  = 2,
    }

    local pos_lbl = Gtk.Label { label = "00:00" }
    pos_lbl:get_style_context():add_class("player-time")
    seek_box:pack_start(pos_lbl, false, false, 0)
    player.pos_label = pos_lbl

    local adj = Gtk.Adjustment {
        lower = 0, upper = 100, value = 0,
        step_increment = 1, page_increment = 10,
    }
    local scale = Gtk.Scale {
        orientation = Gtk.Orientation.HORIZONTAL,
        adjustment  = adj,
        draw_value  = false,
    }
    scale:get_style_context():add_class("player-scale")

    scale.on_button_press_event = function()
        user_seeking = true
        return false
    end
    scale.on_button_release_event = function()
        local val = scale:get_value()
        mpris.seek(val)
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, function()
            user_seeking = false
            return false
        end)
        return false
    end
    scale.on_change_value = function(_, _, new_val)
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

    -- 4) Bottom Row: Synced Lyrics Toggle & Lyrics Offset Controls
    local bottom_box = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL,
        spacing     = 6,
        margin_top  = 2,
    }

    local lyr_btn = Gtk.Button { label = "LETRAS: ON" }
    lyr_btn:get_style_context():add_class("player-pill-active")
    lyr_btn:set_tooltip_text("Activar o desactivar letras sincronizadas")
    lyr_btn.on_clicked = function()
        local cur = (config.skills and config.skills.lyrics ~= false)
        config.skills.lyrics = not cur
        config.LYRICS_ENABLED = config.skills.lyrics
        config.save()
        config.notify_change("lyrics", config.skills.lyrics)
        if not config.LYRICS_ENABLED then
            lyrics.reset()
        else
            lyrics.set_track(mpris.track)
        end
        player.update_ui()
    end
    bottom_box:pack_start(lyr_btn, false, false, 0)
    player.lyr_btn = lyr_btn

    bottom_box:pack_start(Gtk.Label { label = "" }, true, true, 0)

    local sync_lbl = Gtk.Label { label = "SYNC OFFSET:" }
    sync_lbl:get_style_context():add_class("player-time")
    bottom_box:pack_start(sync_lbl, false, false, 0)

    local btn_minus = Gtk.Button { label = "-0.5s" }
    btn_minus:get_style_context():add_class("player-pill")
    btn_minus.on_clicked = function()
        lyrics.adjust_offset(-500)
        player.update_ui()
    end
    bottom_box:pack_start(btn_minus, false, false, 0)

    local offset_lbl = Gtk.Label { label = "+0.0s" }
    offset_lbl:get_style_context():add_class("player-time")
    bottom_box:pack_start(offset_lbl, false, false, 2)
    player.offset_label = offset_lbl

    local btn_plus = Gtk.Button { label = "+0.5s" }
    btn_plus:get_style_context():add_class("player-pill")
    btn_plus.on_clicked = function()
        lyrics.adjust_offset(500)
        player.update_ui()
    end
    bottom_box:pack_start(btn_plus, false, false, 0)

    card:pack_start(bottom_box, false, false, 0)

    win:add(card)

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

    mpris.add_track_listener(function() player.update_ui() end)
    mpris.add_status_listener(function() player.update_ui() end)

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

    mpris.on_art_loaded = function()
        if player.cover_area then
            player.cover_area:queue_draw()
        end
    end
end

-- Compute target coordinates for the mini-player relative to the main bubble
local function calc_target_pos(bx, by, bsize, edge)
    local pw = config.PLAYER_W or 372
    local ph = config.PLAYER_H or 192
    local gap = config.PLAYER_GAP or 10
    local tx, ty = utils.compute_dock(bx, by, bsize, pw, ph, gap, edge or "auto", 8)
    return tx, ty
end

-- Real-time smooth coordinate tracking during bubble drag & edge snap
function player.reposition(bx, by, bsize, edge)
    last_bx = bx or last_bx
    last_by = by or last_by
    last_bsize = bsize or last_bsize
    last_edge = edge or last_edge

    if not player.window or not player.visible then return end

    local tx, ty = calc_target_pos(last_bx, last_by, last_bsize, last_edge)
    if cur_px and cur_py and qwen_native and qwen_native.lerp_point then
        cur_px, cur_py = qwen_native.lerp_point(cur_px, cur_py, tx, ty, 0.65)
    else
        cur_px, cur_py = tx, ty
    end
    player.window:move(math.floor(cur_px), math.floor(cur_py))
end

function player.show(bx, by, bsize, edge)
    player.build()
    if not player.window then return end

    player.visible = true

    last_bx = bx or last_bx
    last_by = by or last_by
    last_bsize = bsize or last_bsize
    last_edge = edge or last_edge

    local tx, ty = calc_target_pos(last_bx, last_by, last_bsize, last_edge)
    cur_px, cur_py = tx, ty

    player.update_ui()
    player.window:move(math.floor(tx), math.floor(ty))
    if not player.window:get_visible() then
        player.window:set_opacity(0)
        player.window:show_all()
    end

    animator.fade(player.window, "in", function()
        schedule_hide_timer()
    end)
end

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

function player.toggle(bx, by, bsize, edge)
    if player.visible then
        player.hide()
    else
        player.show(bx, by, bsize, edge)
    end
end

return player
