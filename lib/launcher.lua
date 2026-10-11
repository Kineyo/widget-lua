----------------------------------------------------------------------
-- launcher.lua  –  Radial "speed-dial" menu that fans out around the orb
--
--   • Opens when the mouse rests on the orb (hover intent) or on demand
--   • Each action is its own tiny transparent window (robust hit-testing,
--     no input-shape tricks), animated with an elastic "pop" from the orb
--   • Fan direction always points towards the screen centre, so it never
--     opens off-screen no matter which edge/corner the orb is docked on
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gtk    = lgi.require("Gtk", "3.0")
local Gdk    = lgi.require("Gdk", "3.0")
local GLib   = lgi.GLib
local Pango  = lgi.Pango
local cairo  = lgi.cairo
local PangoCairo = lgi.PangoCairo

local config   = require("config")
local utils    = require("utils")
local animator = require("animator")

local launcher = {}

launcher.visible    = false
launcher.on_action  = function(id) end     -- set by widget.lua
launcher.get_orb    = function() return 0, 0, config.BUBBLE_SIZE end
launcher.is_blocked = function() return false end

----------------------------------------------------------------------
-- Items (icons are vector paths drawn on a 24x24 grid)
----------------------------------------------------------------------
local PAD = 8   -- transparent padding around each button (shadow room)

local function icon_chat(cr)
    utils.rounded_rect(cr, 3, 4, 18, 12.5, 4.5)
    cr:stroke()
    cr:move_to(8.5, 16.2); cr:line_to(7, 20.5); cr:line_to(12.5, 16.2)
    cr:stroke()
    for _, x in ipairs({ 8.2, 12, 15.8 }) do
        cr:arc(x, 10.2, 0.9, 0, 2 * math.pi); cr:fill()
    end
end

local function icon_music(cr)
    cr:arc(7, 18, 2.8, 0, 2 * math.pi); cr:fill()
    cr:arc(17, 16, 2.8, 0, 2 * math.pi); cr:fill()
    cr:move_to(9.8, 18); cr:line_to(9.8, 6.5); cr:line_to(19.8, 4.5); cr:line_to(19.8, 16)
    cr:stroke()
end

local function icon_pulse(cr)
    cr:move_to(2.5, 12.5); cr:line_to(7, 12.5); cr:line_to(10, 5)
    cr:line_to(14, 19.5); cr:line_to(17, 12.5); cr:line_to(21.5, 12.5)
    cr:stroke()
end

local function icon_camera(cr)
    utils.rounded_rect(cr, 3, 7.5, 18, 12.5, 3.5)
    cr:stroke()
    cr:move_to(8, 7.5); cr:line_to(9.5, 4.5); cr:line_to(14.5, 4.5); cr:line_to(16, 7.5)
    cr:stroke()
    cr:arc(12, 13.7, 3.4, 0, 2 * math.pi)
    cr:stroke()
end

local function icon_spark(cr)
    -- 4-pointed radiant star / sparkle (info / smart data)
    cr:move_to(12, 3)
    cr:curve_to(12, 8, 16, 12, 21, 12)
    cr:curve_to(16, 12, 12, 16, 12, 21)
    cr:curve_to(12, 16, 8, 12, 3, 12)
    cr:curve_to(8, 12, 12, 8, 12, 3)
    cr:close_path()
    cr:fill_preserve()
    cr:stroke()
end

local function icon_power(cr)
    cr:arc(12, 12.8, 7.6, -math.pi / 2 + 0.65, -math.pi / 2 - 0.65 + 2 * math.pi)
    cr:stroke()
    cr:move_to(12, 3.8); cr:line_to(12, 11.5)
    cr:stroke()
end

local ITEMS = {
    { id = "chat",   label = "Chat AI",      color = { 0.545, 0.361, 0.965 }, icon = icon_chat   },
    { id = "bubble", label = "Datos / Info", color = { 0.133, 0.827, 0.933 }, icon = icon_spark  },
    { id = "music",  label = "Música",       color = { 0.957, 0.447, 0.714 }, icon = icon_music  },
    { id = "sys",    label = "Sistema",      color = { 0.204, 0.780, 0.349 }, icon = icon_pulse  },
    { id = "shot",   label = "Captura",      color = { 0.984, 0.749, 0.141 }, icon = icon_camera },
    { id = "quit",   label = "Cerrar",       color = { 0.973, 0.443, 0.443 }, icon = icon_power  },
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local wins        = {}      -- one window per item
local hovered     = nil     -- index of hovered item
local anim        = nil
local show_timer  = nil
local hide_timer  = nil
local label_win   = nil
local label_text  = ""
local label_w, label_h = 0, 0
local targets     = {}      -- per item: final {x, y} (window top-left)
local origin      = { 0, 0 }

local measure_cr = cairo.Context(cairo.ImageSurface(cairo.Format.ARGB32, 1, 1))

local function cancel(t)
    if t then pcall(function() GLib.source_remove(t) end) end
    return nil
end

local function ease_out_back(t)
    local c1 = 1.55
    local c3 = c1 + 1
    return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

local function btn_win_size()
    return (config.LAUNCHER_BTN_SIZE or 44) + PAD * 2
end

----------------------------------------------------------------------
-- Button drawing
----------------------------------------------------------------------
local function draw_button(index)
    return function(self, cr)
        local item = ITEMS[index]
        local W = btn_win_size()
        local c = W / 2
        local R = (config.LAUNCHER_BTN_SIZE or 44) / 2
        local hov = (hovered == index)
        local col = item.color

        cr:set_operator(cairo.Operator.SOURCE)
        cr:set_source_rgba(0, 0, 0, 0)
        cr:paint()
        cr:set_operator(cairo.Operator.OVER)

        local s = hov and 1.12 or 1.0
        cr:save()
        cr:translate(c, c)
        cr:scale(s, s)
        cr:translate(-c, -c)

        -- Soft drop shadow (stacked translucent discs)
        for k = 6, 1, -1 do
            cr:arc(c, c + 2.5, R + k * 0.9, 0, 2 * math.pi)
            cr:set_source_rgba(0, 0, 0, 0.055)
            cr:fill()
        end

        -- Body
        cr:arc(c, c, R, 0, 2 * math.pi)
        local g = cairo.Pattern.create_linear(0, c - R, 0, c + R)
        if hov then
            g:add_color_stop_rgba(0, math.min(1, col[1] + 0.18), math.min(1, col[2] + 0.18), math.min(1, col[3] + 0.18), 1)
            g:add_color_stop_rgba(1, col[1], col[2], col[3], 1)
        else
            g:add_color_stop_rgba(0, 0.16, 0.14, 0.29, 0.97)
            g:add_color_stop_rgba(1, 0.085, 0.075, 0.175, 0.97)
        end
        cr:set_source(g)
        cr:fill_preserve()

        -- Ring
        cr:set_line_width(hov and 1.2 or 1.6)
        if hov then
            cr:set_source_rgba(1, 1, 1, 0.55)
        else
            cr:set_source_rgba(col[1], col[2], col[3], 0.80)
        end
        cr:stroke()

        -- Top glass highlight
        cr:save()
        cr:arc(c, c, R - 1.5, 0, 2 * math.pi)
        cr:clip()
        local hl = cairo.Pattern.create_linear(0, c - R, 0, c)
        hl:add_color_stop_rgba(0, 1, 1, 1, hov and 0.28 or 0.10)
        hl:add_color_stop_rgba(1, 1, 1, 1, 0)
        cr:set_source(hl)
        cr:rectangle(c - R, c - R, R * 2, R)
        cr:fill()
        cr:restore()

        -- Icon
        local isz = 20
        cr:save()
        cr:translate(c - isz / 2, c - isz / 2)
        cr:scale(isz / 24, isz / 24)
        cr:set_line_width(1.9)
        cr:set_line_cap(cairo.LineCap.ROUND)
        cr:set_line_join(cairo.LineJoin.ROUND)
        if hov then
            cr:set_source_rgba(1, 1, 1, 1)
        else
            cr:set_source_rgba(math.min(1, col[1] + 0.25), math.min(1, col[2] + 0.25), math.min(1, col[3] + 0.25), 1)
        end
        item.icon(cr)
        cr:restore()

        cr:restore()
        return true
    end
end

----------------------------------------------------------------------
-- Tooltip-like label pill
----------------------------------------------------------------------
local function ensure_label()
    if label_win then return end
    label_win = Gtk.Window {
        type = Gtk.WindowType.POPUP,
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = false,
        accept_focus = false,
        type_hint = Gdk.WindowTypeHint.TOOLTIP,
    }
    label_win:set_keep_above(true)
    label_win:set_app_paintable(true)
    local visual = label_win:get_screen():get_rgba_visual()
    if visual then label_win:set_visual(visual) end

    label_win.on_draw = function(self, cr)
        local w = self:get_allocated_width()
        local h = self:get_allocated_height()
        cr:set_operator(cairo.Operator.SOURCE)
        cr:set_source_rgba(0, 0, 0, 0)
        cr:paint()
        cr:set_operator(cairo.Operator.OVER)

        utils.rounded_rect(cr, 1, 1, w - 2, h - 2, (h - 2) / 2)
        local g = cairo.Pattern.create_linear(0, 0, 0, h)
        g:add_color_stop_rgba(0, 0.16, 0.14, 0.29, 0.97)
        g:add_color_stop_rgba(1, 0.085, 0.075, 0.175, 0.97)
        cr:set_source(g)
        cr:fill_preserve()
        cr:set_source_rgba(1, 1, 1, 0.14)
        cr:set_line_width(1)
        cr:stroke()

        local layout = PangoCairo.create_layout(cr)
        layout:set_font_description(Pango.FontDescription.from_string("Sans Bold 9"))
        layout:set_text(label_text, -1)
        local _, ext = layout:get_pixel_extents()
        cr:set_source_rgba(0.95, 0.95, 1, 1)
        cr:move_to((w - ext.width) / 2, (h - ext.height) / 2 - 0.5)
        PangoCairo.show_layout(cr, layout)
        return true
    end
end

local function hide_label()
    if label_win then label_win:hide() end
end

local function show_label(index)
    ensure_label()
    local item = ITEMS[index]
    label_text = item.label

    local layout = PangoCairo.create_layout(measure_cr)
    layout:set_font_description(Pango.FontDescription.from_string("Sans Bold 9"))
    layout:set_text(label_text, -1)
    local _, ext = layout:get_pixel_extents()
    label_w = ext.width + 22
    label_h = ext.height + 10

    local t = targets[index]
    if not t then return end
    local W = btn_win_size()
    local bcx, bcy = t[1] + W / 2, t[2] + W / 2
    local dx, dy = bcx - origin[1], bcy - origin[2]
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then len = 1 end
    dx, dy = dx / len, dy / len

    local reach = (config.LAUNCHER_BTN_SIZE or 44) / 2 + 10
    local lx = bcx + dx * reach + dx * label_w / 2 - label_w / 2
    local ly = bcy + dy * reach + dy * label_h / 2 - label_h / 2

    local screen = Gdk.Screen.get_default()
    lx = math.max(4, math.min(lx, screen:get_width() - label_w - 4))
    ly = math.max(4, math.min(ly, screen:get_height() - label_h - 4))

    label_win:set_size_request(label_w, label_h)
    label_win:resize(label_w, label_h)
    label_win:move(math.floor(lx), math.floor(ly))
    label_win:show_all()
    label_win:queue_draw()
end

----------------------------------------------------------------------
-- Build windows (once)
----------------------------------------------------------------------
local function ensure_windows()
    if #wins > 0 then return end
    local W = btn_win_size()

    for i, item in ipairs(ITEMS) do
        local w = Gtk.Window {
            type = Gtk.WindowType.POPUP,
            decorated = false,
            skip_taskbar_hint = true,
            skip_pager_hint = true,
            resizable = false,
            accept_focus = false,
            type_hint = Gdk.WindowTypeHint.DOCK,
            default_width = W,
            default_height = W,
        }
        w:set_keep_above(true)
        w:set_app_paintable(true)
        w:set_size_request(W, W)
        local visual = w:get_screen():get_rgba_visual()
        if visual then w:set_visual(visual) end

        w:add_events(Gdk.EventMask.BUTTON_PRESS_MASK +
                     Gdk.EventMask.ENTER_NOTIFY_MASK +
                     Gdk.EventMask.LEAVE_NOTIFY_MASK)

        w.on_draw = draw_button(i)

        w.on_enter_notify_event = function()
            hide_timer = cancel(hide_timer)
            hovered = i
            w:queue_draw()
            show_label(i)
            return false
        end
        w.on_leave_notify_event = function()
            if hovered == i then hovered = nil end
            w:queue_draw()
            hide_label()
            launcher.schedule_hide()
            return false
        end
        w.on_button_press_event = function(_, event)
            if event.button == 1 then
                launcher.hide(true)
                launcher.on_action(item.id)
                return true
            end
            return false
        end

        wins[i] = w
    end
end

----------------------------------------------------------------------
-- Layout: fan of buttons pointing at the screen centre
----------------------------------------------------------------------
local function compute_targets(bx, by, bsize)
    local screen = Gdk.Screen.get_default()
    local sw, sh = screen:get_width(), screen:get_height()
    local ocx, ocy = bx + bsize / 2, by + bsize / 2
    origin = { ocx, ocy }

    local base = math.atan2(sh / 2 - ocy, sw / 2 - ocx)
    local n = #ITEMS
    local span = math.rad(config.LAUNCHER_SPAN_DEG or 168)
    local step = span / (n - 1)
    local R = config.LAUNCHER_RADIUS or 76
    local W = btn_win_size()

    targets = {}
    for i = 1, n do
        local a = base - (i - (n + 1) / 2) * step
        local cx = ocx + R * math.cos(a)
        local cy = ocy + R * math.sin(a)
        local x = math.max(2, math.min(cx - W / 2, sw - W - 2))
        local y = math.max(2, math.min(cy - W / 2, sh - W - 2))
        targets[i] = { x, y }
    end
end

local function apply_progress(t)
    local n = #ITEMS
    local W = btn_win_size()
    local stagger = 0.07
    for i = 1, n do
        local ti = (t - (i - 1) * stagger) / (1 - (n - 1) * stagger)
        ti = math.max(0, math.min(1, ti))
        local p = ease_out_back(ti)
        local tg = targets[i]
        local x = origin[1] - W / 2 + (tg[1] - (origin[1] - W / 2)) * p
        local y = origin[2] - W / 2 + (tg[2] - (origin[2] - W / 2)) * p
        wins[i]:move(math.floor(x), math.floor(y))
        wins[i]:set_opacity(math.min(1, ti * 1.8))
    end
end

local function ensure_anim()
    if anim then return end
    anim = animator.new({
        duration = config.LAUNCHER_ANIM_MS or 320,
        ease = function(t) return t end,   -- easing handled per item
        on_update = function(t) apply_progress(t) end,
        on_complete = function()
            if anim.value <= 0 then
                for _, w in ipairs(wins) do w:hide() end
                launcher.visible = false
            end
        end,
    })
end

local function run_anim(forward)
    ensure_anim()
    anim.forward = forward
    if not anim.running then anim:start() end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function launcher.show()
    if not config.LAUNCHER_ENABLED then return end
    if launcher.is_blocked() then return end
    show_timer = cancel(show_timer)
    hide_timer = cancel(hide_timer)

    ensure_windows()
    local bx, by, bsize = launcher.get_orb()
    compute_targets(bx, by, bsize)

    if not launcher.visible then
        hovered = nil
        apply_progress(0)
        for _, w in ipairs(wins) do
            w:set_opacity(0)
            w:show_all()
        end
        launcher.visible = true
        ensure_anim()
        anim.value = 0
    else
        apply_progress(anim and anim.value or 1)
    end
    run_anim(true)
end

function launcher.hide(instant)
    show_timer = cancel(show_timer)
    hide_timer = cancel(hide_timer)
    hide_label()
    hovered = nil
    if #wins == 0 or not launcher.visible then return end

    if instant then
        if anim then anim:stop(); anim.value = 0 end
        for _, w in ipairs(wins) do w:hide() end
        launcher.visible = false
    else
        run_anim(false)
    end
end

function launcher.schedule_hide(ms)
    hide_timer = cancel(hide_timer)
    hide_timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms or config.LAUNCHER_LEAVE_MS or 480, function()
        hide_timer = nil
        launcher.hide(false)
        return false
    end)
end

-- Mouse entered the orb: open after a short "hover intent" delay
function launcher.orb_enter()
    if not config.LAUNCHER_ENABLED then return end
    hide_timer = cancel(hide_timer)
    if launcher.visible then
        -- Closing animation might be in progress → reopen
        if anim and not anim.forward then run_anim(true) end
        return
    end
    show_timer = cancel(show_timer)
    show_timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, config.LAUNCHER_HOVER_MS or 220, function()
        show_timer = nil
        launcher.show()
        return false
    end)
end

-- Mouse left the orb: cancel pending open / schedule close
function launcher.orb_leave()
    show_timer = cancel(show_timer)
    if launcher.visible then launcher.schedule_hide() end
end

-- Re-anchor while the orb is being dragged / snapped
function launcher.reposition()
    if not launcher.visible then return end
    local bx, by, bsize = launcher.get_orb()
    compute_targets(bx, by, bsize)
    apply_progress(anim and anim.value or 1)
end

function launcher.toggle()
    if launcher.visible then
        launcher.hide(false)
    else
        launcher.show()
    end
end

return launcher
