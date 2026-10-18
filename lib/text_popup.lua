----------------------------------------------------------------------
-- text_popup.lua  –  Corrector Gramatical Automatico y Menu Contextual
--                    Usa hooks nativos C/C++ (X11/XFixes/XInput2 + Wayland)
--                    para aparicion instantanea al seleccionar texto.
--                    Cero emojis y contraste garantizado en todos los estados.
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gtk    = lgi.require("Gtk", "3.0")
local Gdk    = lgi.require("Gdk", "3.0")
local GLib   = lgi.GLib
local Gio    = lgi.Gio
local cairo  = lgi.cairo

local config   = require("config")
local utils    = require("utils")
local writing  = require("skills.writing")

local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local text_popup = {}

text_popup.window           = nil
text_popup.visible          = false
text_popup.current_text     = nil
text_popup.last_text        = nil
text_popup.watcher_sub_p    = nil
text_popup.watcher_sub_c    = nil
text_popup._native_poll_id  = nil
text_popup._running         = false
text_popup._processing      = false
text_popup._suppress_until  = 0
text_popup._proximity_timer = nil
text_popup._is_expanded     = false
text_popup.on_state_change  = nil -- function("grammar" | "idle")

----------------------------------------------------------------------
-- Explicit High-Contrast Color Palette Variables (Guaranteed Legibility)
----------------------------------------------------------------------
local PALETTE = {
    window_bg       = "#0D0F18",
    window_border   = "#3B82F6",
    normal_bg       = "#131726",
    normal_fg       = "#F8FAFC",
    hover_bg        = "#F8FAFC",
    hover_fg        = "#090A10",
    active_bg       = "#2563EB",
    active_fg       = "#FFFFFF",
    disabled_bg     = "#1E2235",
    disabled_fg     = "#94A3B8",
    primary_btn_bg  = "#F8FAFC",
    primary_btn_fg  = "#090A10",
    secondary_bg    = "#1E253C",
    secondary_fg    = "#F8FAFC",
}

local CSS = string.format([[
.popup-window {
    background-color: transparent;
}
.popup-bar {
    background-color: transparent;
    padding: 4px 5px;
}

button.popup-item,
.popup-item {
    background-color: %s;
    background-image: none;
    color: %s;
    box-shadow: none;
    text-shadow: none;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 7px;
    padding: 6px 14px;
    margin: 1px 0px;
}
button.popup-item label,
.popup-item label {
    color: %s;
    font-size: 13.5px;
    font-weight: 600;
}
button.popup-item:hover,
.popup-item:hover {
    background-color: %s;
    background-image: none;
    color: %s;
    border: 1px solid #FFFFFF;
}
button.popup-item:hover label,
.popup-item:hover label {
    color: %s;
    font-weight: bold;
}
button.popup-item:active,
.popup-item:active {
    background-color: %s;
    background-image: none;
    color: %s;
}
button.popup-item:active label,
.popup-item:active label {
    color: %s;
}
button.popup-item:disabled,
.popup-item:disabled {
    background-color: %s;
    background-image: none;
    color: %s;
}
button.popup-item:disabled label,
.popup-item:disabled label {
    color: %s;
}

button.popup-more,
.popup-more {
    background-color: %s;
    background-image: none;
    color: #93C5FD;
    border: 1px solid rgba(59, 130, 246, 0.25);
    border-radius: 7px;
    padding: 5px 14px;
    margin: 2px 0px;
}
button.popup-more label,
.popup-more label {
    color: #93C5FD;
    font-size: 12.5px;
    font-weight: 600;
}
button.popup-more:hover,
.popup-more:hover {
    background-color: %s;
    background-image: none;
    color: %s;
}
button.popup-more:hover label,
.popup-more:hover label {
    color: %s;
    font-weight: bold;
}

.popup-separator {
    background-color: rgba(255, 255, 255, 0.15);
    margin: 4px 4px;
}
.popup-title {
    color: #F8FAFC;
    font-size: 13.5px;
    font-weight: bold;
}
.popup-status {
    color: #F8FAFC;
    font-size: 13px;
    font-weight: 600;
    padding: 4px 6px;
}

button.popup-btn-white,
.popup-btn-white {
    background-color: %s;
    background-image: none;
    color: %s;
    border-radius: 7px;
    font-size: 13px;
    font-weight: bold;
    border: 1px solid #FFFFFF;
    padding: 6px 14px;
}
button.popup-btn-white label,
.popup-btn-white label {
    color: %s;
    font-size: 13px;
    font-weight: bold;
}
button.popup-btn-white:hover,
.popup-btn-white:hover {
    background-color: %s;
    background-image: none;
    color: %s;
    border: 1px solid #60A5FA;
}
button.popup-btn-white:hover label,
.popup-btn-white:hover label {
    color: %s;
}

button.popup-btn-dark,
.popup-btn-dark {
    background-color: %s;
    background-image: none;
    color: %s;
    border-radius: 7px;
    font-size: 13px;
    font-weight: 600;
    border: 1px solid rgba(255, 255, 255, 0.25);
    padding: 6px 12px;
}
button.popup-btn-dark label,
.popup-btn-dark label {
    color: %s;
    font-size: 13px;
    font-weight: 600;
}
button.popup-btn-dark:hover,
.popup-btn-dark:hover {
    background-color: %s;
    background-image: none;
    color: %s;
    border: 1px solid #FFFFFF;
}
button.popup-btn-dark:hover label,
.popup-btn-dark:hover label {
    color: %s;
}

.popup-result-view {
    background-color: #090A10;
    background-image: none;
    color: #F8FAFC;
    font-size: 13.5px;
    border-radius: 8px;
    padding: 8px 10px;
    border: 1px solid rgba(255, 255, 255, 0.28);
}
.popup-result-view text {
    background-color: #090A10;
    color: #F8FAFC;
    font-size: 13.5px;
}
]],
    PALETTE.normal_bg, PALETTE.normal_fg, PALETTE.normal_fg,
    PALETTE.hover_bg, PALETTE.hover_fg, PALETTE.hover_fg,
    PALETTE.active_bg, PALETTE.active_fg, PALETTE.active_fg,
    PALETTE.disabled_bg, PALETTE.disabled_fg, PALETTE.disabled_fg,
    PALETTE.normal_bg,
    PALETTE.hover_bg, PALETTE.hover_fg, PALETTE.hover_fg,
    PALETTE.primary_btn_bg, PALETTE.primary_btn_fg, PALETTE.primary_btn_fg,
    PALETTE.active_bg, PALETTE.active_fg, PALETTE.active_fg,
    PALETTE.secondary_bg, PALETTE.secondary_fg, PALETTE.secondary_fg,
    PALETTE.hover_bg, PALETTE.hover_fg, PALETTE.hover_fg
)

local css_applied = false
local function apply_css()
    if css_applied then return end
    css_applied = true
    local provider = Gtk.CssProvider()
    pcall(function()
        provider:load_from_data(CSS, #CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_USER)
    end)
end

----------------------------------------------------------------------
-- Native C/C++ Cursor Position with GDK Fallback
----------------------------------------------------------------------
local function get_mouse_location()
    if qwen_native and qwen_native.get_cursor_pos then
        local mx, my = qwen_native.get_cursor_pos()
        if mx and my and (mx > 0 or my > 0) then
            return mx, my
        end
    end

    local ok_gdk, gx, gy = pcall(function()
        local seat = Gdk.Display.get_default():get_default_seat()
        local pointer = seat and seat:get_pointer()
        if pointer then
            local _, cx, cy = pointer:get_position()
            return cx, cy
        end
        return nil, nil
    end)
    if ok_gdk and gx and gy and (gx > 0 or gy > 0) then
        return gx, gy
    end

    return nil, nil
end

local function suppress_hooks(ms)
    local dur = ms or 2200
    text_popup._suppress_until = GLib.get_monotonic_time() + (dur * 1000)
    if qwen_native and qwen_native.suppress_selection then
        pcall(qwen_native.suppress_selection, dur)
    end
end

local function copy_to_clipboard(str)
    if not str or #str == 0 then return end
    suppress_hooks(2200)
    text_popup.last_text    = str
    text_popup.current_text = str

    pcall(function()
        local clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        if clip then clip:set_text(str, -1) end
    end)

    pcall(Gio.Subprocess.new,
        { "bash", "-c", string.format("printf '%%s' %q | (/home/alex/.local/bin/wl-copy 2>/dev/null || wl-copy 2>/dev/null || xclip -selection clipboard 2>/dev/null || true)", str) },
        Gio.SubprocessFlags.NONE)
end

local function insert_text(str)
    if not str or #str == 0 then return end
    suppress_hooks(2500)
    text_popup.last_text = str
    copy_to_clipboard(str)
    text_popup.hide()

    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 120, function()
        local is_wayland = (os.getenv("WAYLAND_DISPLAY") ~= nil and #os.getenv("WAYLAND_DISPLAY") > 0)
        local ok_wtype = false
        if is_wayland then
            local wtype_bin = "/home/alex/.local/bin/wtype"
            local f = io.open(wtype_bin, "r")
            if f then
                f:close()
                local ok, proc = pcall(Gio.Subprocess.new, { wtype_bin, "-M", "ctrl", "-k", "v", "-m", "ctrl" }, Gio.SubprocessFlags.NONE)
                if ok and proc then ok_wtype = true end
            end
        end
        if not ok_wtype then
            pcall(Gio.Subprocess.new, {
                "bash", "-c",
                "LD_LIBRARY_PATH=/home/alex/.local/lib:${LD_LIBRARY_PATH:-} /home/alex/.local/bin/xdotool key --clearmodifiers ctrl+v 2>/dev/null || xdotool key --clearmodifiers ctrl+v 2>/dev/null || true"
            }, Gio.SubprocessFlags.NONE)
        end
        return false
    end)
end

local function adjust_position()
    if not text_popup.window or not text_popup.visible then return end
    text_popup.window:check_resize()
    local x, y = text_popup.window:get_position()
    local w, h = text_popup.window:get_size()
    local nx, ny = utils.clamp_to_screen(x, y, w, h, 12)
    if nx ~= x or ny ~= y then
        text_popup.window:move(nx, ny)
    end
end

function text_popup.build()
    if text_popup.window then return end
    apply_css()

    local win = Gtk.Window {
        type = Gtk.WindowType.TOPLEVEL,
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = true,
        accept_focus = false,
        focus_on_map = false,
        type_hint = Gdk.WindowTypeHint.UTILITY,
    }
    win:set_keep_above(true)
    win:get_style_context():add_class("popup-window")

    local screen = win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then win:set_visual(visual) end
    win:set_app_paintable(true)

    win.on_draw = function(self, cr)
        local w = self:get_allocated_width()
        local h = self:get_allocated_height()
        cr:set_operator(cairo.Operator.SOURCE)
        cr:set_source_rgba(0, 0, 0, 0)
        cr:paint()
        cr:set_operator(cairo.Operator.OVER)

        for k = 2, 1, -1 do
            cr:new_sub_path()
            utils.rounded_rect(cr, 1, 1 + k * 0.8, w - 2, h - 2, 9)
            cr:set_source_rgba(0, 0, 0, 0.14 * (3 - k))
            cr:fill()
        end

        utils.rounded_rect(cr, 1, 1, w - 2, h - 2, 9)
        cr:set_source_rgba(0.055, 0.065, 0.105, 0.98)
        cr:fill_preserve()

        cr:set_source_rgba(config.ACCENT[1], config.ACCENT[2], config.ACCENT[3], 0.65)
        cr:set_line_width(1.3)
        cr:stroke()
        return false
    end

    local main_box = Gtk.Box {
        orientation = Gtk.Orientation.VERTICAL,
        spacing = 0,
        margin_start = 6, margin_end = 6,
        margin_top = 5, margin_bottom = 5,
    }
    main_box:get_style_context():add_class("popup-bar")
    win:add(main_box)

    text_popup.window   = win
    text_popup.main_box = main_box
end

local function clear_main_box()
    if not text_popup.main_box then return end
    local children = text_popup.main_box:get_children()
    for _, child in ipairs(children) do
        text_popup.main_box:remove(child)
    end
end

function text_popup.show_menu(raw_text, expanded)
    if not text_popup.main_box then return end
    clear_main_box()

    text_popup._is_expanded = (expanded == true)
    local all_actions = writing.get_enabled_actions()
    if #all_actions == 0 then
        text_popup.hide()
        return
    end

    local v_box = Gtk.Box {
        orientation = Gtk.Orientation.VERTICAL,
        spacing = 2,
    }

    local limit = text_popup._is_expanded and #all_actions or math.min(5, #all_actions)

    for i = 1, limit do
        local act = all_actions[i]
        local label_text = act.short_label or act.label
        local btn = Gtk.Button { label = label_text }
        btn:get_style_context():add_class("popup-item")
        if btn:get_child() and btn:get_child().set_xalign then
            pcall(function() btn:get_child():set_xalign(0) end)
        end
        btn:set_tooltip_text(act.label .. ": " .. act.instruction)

        local target_act = act
        btn.on_clicked = function()
            text_popup.process_action(target_act, raw_text)
        end
        v_box:pack_start(btn, false, false, 0)
    end

    if #all_actions > 5 then
        local sep = Gtk.Separator { orientation = Gtk.Orientation.HORIZONTAL }
        sep:get_style_context():add_class("popup-separator")
        v_box:pack_start(sep, false, false, 2)

        local more_label = text_popup._is_expanded and "Menos opciones" or "Mas opciones"
        local more_btn = Gtk.Button { label = more_label }
        more_btn:get_style_context():add_class("popup-more")
        if more_btn:get_child() and more_btn:get_child().set_xalign then
            pcall(function() more_btn:get_child():set_xalign(0) end)
        end
        more_btn.on_clicked = function()
            text_popup.show_menu(raw_text, not text_popup._is_expanded)
            adjust_position()
        end
        v_box:pack_start(more_btn, false, false, 0)
    end

    text_popup.main_box:pack_start(v_box, true, true, 0)
    if text_popup.window then
        text_popup.window:show_all()
        text_popup.window:resize(1, 1)
        text_popup.window:check_resize()
        adjust_position()
    else
        text_popup.main_box:show_all()
    end
end

function text_popup.process_action(act, raw_text)
    clear_main_box()
    text_popup._processing = true
    if text_popup.on_state_change then pcall(text_popup.on_state_change, "grammar") end

    local load_box = Gtk.Box {
        orientation = Gtk.Orientation.VERTICAL,
        spacing = 8,
        margin_start = 6, margin_end = 6,
        margin_top = 8, margin_bottom = 8,
    }

    local model_name = (config.inference_provider == "cloud")
        and ("Cloud (" .. (config.cloud_provider or "API") .. ")")
        or (config.grammar_model or "es-grammar.gguf")

    local status_lbl = Gtk.Label {
        label = string.format("Procesando con %s...", model_name)
    }
    status_lbl:get_style_context():add_class("popup-status")
    load_box:pack_start(status_lbl, false, false, 4)

    local cancel_btn = Gtk.Button { label = "Cancelar" }
    cancel_btn:get_style_context():add_class("popup-btn-dark")
    cancel_btn.on_clicked = function()
        text_popup._processing = false
        if text_popup.on_state_change then pcall(text_popup.on_state_change, "idle") end
        text_popup.show_menu(raw_text, false)
    end
    load_box:pack_start(cancel_btn, false, false, 0)

    text_popup.main_box:pack_start(load_box, true, true, 0)
    if text_popup.window then
        text_popup.window:show_all()
        text_popup.window:resize(1, 1)
        text_popup.window:check_resize()
    else
        text_popup.main_box:show_all()
    end

    writing.transform(act.id, raw_text, function(ok, result)
        GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
            text_popup._processing = false
            if text_popup.on_state_change then pcall(text_popup.on_state_change, "idle") end
            if not text_popup.visible or not text_popup.window then return false end
            if ok and result then
                text_popup.show_result(act, raw_text, result)
            else
                text_popup.show_error(act, raw_text, tostring(result or "Error desconocido"))
            end
            return false
        end)
    end)
end

function text_popup.show_result(act, raw_text, result)
    clear_main_box()

    local result_box = Gtk.Box {
        orientation = Gtk.Orientation.VERTICAL,
        spacing = 8,
        margin_start = 6, margin_end = 6,
        margin_top = 6, margin_bottom = 6,
    }

    local top_bar = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL, spacing = 8 }
    local title_lbl = Gtk.Label { label = act.short_label or act.label }
    title_lbl:get_style_context():add_class("popup-title")
    top_bar:pack_start(title_lbl, false, false, 0)
    top_bar:pack_start(Gtk.Label { label = "" }, true, true, 0)

    local close_btn = Gtk.Button { label = "Cerrar" }
    close_btn:get_style_context():add_class("popup-btn-dark")
    close_btn.on_clicked = function() text_popup.hide() end
    top_bar:pack_end(close_btn, false, false, 0)
    result_box:pack_start(top_bar, false, false, 0)

    local sw = Gtk.ScrolledWindow {
        hscrollbar_policy = Gtk.PolicyType.NEVER,
        vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
        min_content_height = 80,
        max_content_height = 180,
        width_request = 380,
    }
    local tv = Gtk.TextView {
        editable = false,
        cursor_visible = false,
        wrap_mode = Gtk.WrapMode.WORD_CHAR,
    }
    tv:get_style_context():add_class("popup-result-view")
    tv:get_buffer():set_text(result, -1)
    sw:add(tv)
    result_box:pack_start(sw, true, true, 0)

    local btn_row = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL, spacing = 8, margin_top = 4 }

    local insert_btn = Gtk.Button { label = "Reemplazar" }
    insert_btn:get_style_context():add_class("popup-btn-white")
    insert_btn:set_tooltip_text("Insertar texto directamente reemplazando la seleccion")
    insert_btn.on_clicked = function()
        insert_btn:set_label("Insertado")
        insert_text(result)
    end
    btn_row:pack_start(insert_btn, true, true, 0)

    local copy_btn = Gtk.Button { label = "Copiar" }
    copy_btn:get_style_context():add_class("popup-btn-dark")
    copy_btn:set_tooltip_text("Copiar al portapapeles")
    copy_btn.on_clicked = function()
        copy_to_clipboard(result)
        copy_btn:set_label("Copiado")
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 650, function()
            text_popup.hide()
            return false
        end)
    end
    btn_row:pack_start(copy_btn, true, true, 0)

    local back_btn = Gtk.Button { label = "Volver" }
    back_btn:get_style_context():add_class("popup-btn-dark")
    back_btn.on_clicked = function()
        text_popup.show_menu(raw_text, false)
    end
    btn_row:pack_end(back_btn, false, false, 0)

    result_box:pack_start(btn_row, false, false, 0)
    text_popup.main_box:pack_start(result_box, true, true, 0)

    if text_popup.window then
        text_popup.window:show_all()
        text_popup.window:resize(1, 1)
        text_popup.window:check_resize()
        adjust_position()
    else
        text_popup.main_box:show_all()
    end
end

function text_popup.show_error(act, raw_text, err_msg)
    clear_main_box()

    local err_box = Gtk.Box { orientation = Gtk.Orientation.VERTICAL, spacing = 8, margin = 8 }
    local err_lbl = Gtk.Label { label = "Aviso: " .. tostring(err_msg) }
    err_lbl:get_style_context():add_class("popup-status")
    err_box:pack_start(err_lbl, false, false, 4)

    local btn_row = Gtk.Box { orientation = Gtk.Orientation.HORIZONTAL, spacing = 8 }
    local back_btn = Gtk.Button { label = "Volver" }
    back_btn:get_style_context():add_class("popup-btn-dark")
    back_btn.on_clicked = function() text_popup.show_menu(raw_text, false) end
    btn_row:pack_start(back_btn, true, true, 0)

    local close_btn = Gtk.Button { label = "Cerrar" }
    close_btn:get_style_context():add_class("popup-btn-dark")
    close_btn.on_clicked = function() text_popup.hide() end
    btn_row:pack_end(close_btn, false, false, 0)

    err_box:pack_start(btn_row, false, false, 0)
    text_popup.main_box:pack_start(err_box, true, true, 0)

    if text_popup.window then
        text_popup.window:show_all()
        text_popup.window:resize(1, 1)
        text_popup.window:check_resize()
    else
        text_popup.main_box:show_all()
    end
end

function text_popup.show(raw_text, target_x, target_y)
    if not config.skills or config.skills.global_text_menu == false then
        return
    end
    if not raw_text or #raw_text:gsub("%s+", "") < 2 then
        return
    end

    text_popup.build()
    if not text_popup.window then return end

    text_popup.current_text = raw_text
    text_popup.show_menu(raw_text, false)

    local sw, sh = utils.screen_size()
    local px, py = target_x, target_y

    if not px or not py or px <= 0 or py <= 0 then
        px, py = get_mouse_location()
    end
    if not px or not py or px <= 0 or py <= 0 or px >= sw or py >= sh then
        px = math.floor(sw / 2)
        py = math.floor(sh / 2)
    end

    text_popup.window:show_all()
    text_popup.window:check_resize()

    local win_w, win_h = text_popup.window:get_size()
    if not win_w or win_w < 80 then win_w = 165 end
    if not win_h or win_h < 50 then win_h = 220 end

    local x = math.floor(px + 10)
    if x + win_w > sw - 12 then
        x = math.floor(px - win_w - 10)
    end
    local y = math.floor(py - 10)
    x, y = utils.clamp_to_screen(x, y, win_w, win_h, 12)

    text_popup.window:move(x, y)
    text_popup.window:set_keep_above(true)
    text_popup.visible = true

    if text_popup._proximity_timer then
        GLib.source_remove(text_popup._proximity_timer)
        text_popup._proximity_timer = nil
    end
    text_popup._proximity_timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, function()
        if not text_popup.visible or not text_popup.window or text_popup._processing then
            text_popup._proximity_timer = nil
            return false
        end
        local mx, my = get_mouse_location()
        if mx and my and mx > 0 and my > 0 then
            local wx, wy = text_popup.window:get_position()
            local ww, wh = text_popup.window:get_size()
            local dx = math.max(0, wx - mx, mx - (wx + ww))
            local dy = math.max(0, wy - my, my - (wy + wh))
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > 200 then
                text_popup.hide()
                text_popup._proximity_timer = nil
                return false
            end
        end
        return true
    end)
end

function text_popup.hide()
    if text_popup._proximity_timer then
        GLib.source_remove(text_popup._proximity_timer)
        text_popup._proximity_timer = nil
    end
    if text_popup.window and text_popup.visible then
        text_popup.window:hide()
        text_popup.visible = false
        text_popup.current_text = nil
        if text_popup.on_state_change then pcall(text_popup.on_state_change, "idle") end
        collectgarbage("step", 50)
    end
end

local function handle_selection_event(raw_text, cx, cy)
    if not config.skills or config.skills.global_text_menu == false then return end
    if text_popup._suppress_until and GLib.get_monotonic_time() < text_popup._suppress_until then
        return
    end

    local clean = (raw_text or ""):gsub("^%s*(.-)%s*$", "%1")
    if #clean < 2 or #clean > 20000 then
        if text_popup.visible and not text_popup._processing then
            text_popup.hide()
        end
        return
    end

    if text_popup.visible and clean == text_popup.current_text then return end
    text_popup.last_text = clean

    local mx, my = cx, cy
    if not mx or not my or (mx <= 0 and my <= 0) then
        mx, my = get_mouse_location()
    end

    GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
        text_popup.show(clean, mx, my)
        return false
    end)
end

local function handle_clipboard_event()
    if text_popup._suppress_until and GLib.get_monotonic_time() < text_popup._suppress_until then
        return
    end
    if text_popup.visible and not text_popup._processing then
        GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
            text_popup.hide()
            return false
        end)
    end
end

local function spawn_watcher(args, on_event)
    local ok, sub = pcall(Gio.Subprocess.new, args,
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE)
    if not ok or not sub then return nil end

    local stdout = sub:get_stdout_pipe()
    local stream = Gio.DataInputStream.new(stdout)
    local buffer_chunks = {}

    local function read_line()
        if not text_popup._running then return end
        stream:read_line_async(GLib.PRIORITY_DEFAULT, nil, function(src, res)
            local line = src:read_line_finish(res)
            if line == nil then return end
            local str = type(line) == "string" and line or tostring(line)
            if str == "__SELECTION_EVENT_DELIM__" then
                local full_text = table.concat(buffer_chunks, "\n")
                buffer_chunks = {}
                on_event(full_text)
            else
                buffer_chunks[#buffer_chunks + 1] = str
            end
            read_line()
        end)
    end

    read_line()
    return sub
end

function text_popup.start_watcher()
    if text_popup._running then return end
    if not config.skills or config.skills.global_text_menu == false then return end

    text_popup._running = true

    -- 1. Start Native C/C++ OS Selection Hook (X11/XFixes/XInput2 thread)
    if qwen_native and qwen_native.start_selection_hook then
        pcall(qwen_native.start_selection_hook)
        text_popup._native_poll_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 35, function()
            if not text_popup._running then
                text_popup._native_poll_id = nil
                return false
            end
            local ev = qwen_native.poll_selection()
            if ev then
                if ev.clipboard_copied then
                    handle_clipboard_event()
                elseif ev.text and #ev.text > 0 then
                    handle_selection_event(ev.text, ev.x, ev.y)
                end
            end
            return true
        end)
    end

    -- 2. Wayland wl-paste stream watcher (complements native X11 hook on Wayland/COSMIC)
    local wl_cmd = "wl-paste"
    local f_wl = io.open("/home/alex/.local/bin/wl-paste", "r")
    if f_wl then
        f_wl:close()
        wl_cmd = "/home/alex/.local/bin/wl-paste"
    end

    text_popup.watcher_sub_p = spawn_watcher({
        wl_cmd, "-p", "-w",
        "sh", "-c", "cat; printf '\\n__SELECTION_EVENT_DELIM__\\n'"
    }, function(txt) handle_selection_event(txt) end)

    text_popup.watcher_sub_c = spawn_watcher({
        wl_cmd, "-w",
        "sh", "-c", "cat >/dev/null; printf '__SELECTION_EVENT_DELIM__\\n'"
    }, function(_) handle_clipboard_event() end)

    -- 3. GTK Primary Selection owner-change fallback
    pcall(function()
        local prim = Gtk.Clipboard.get(Gdk.SELECTION_PRIMARY)
        if prim and not text_popup._owner_connected then
            text_popup._owner_connected = true
            prim.on_owner_change = function(clipboard)
                if not config.skills or config.skills.global_text_menu == false then return end
                clipboard:request_text(function(_, text)
                    if text then handle_selection_event(text) end
                end)
            end
        end
    end)

    pcall(function()
        local clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        if clip and not text_popup._clip_owner_connected then
            text_popup._clip_owner_connected = true
            clip.on_owner_change = function()
                handle_clipboard_event()
            end
        end
    end)
end

function text_popup.stop_watcher()
    text_popup._running = false
    if text_popup._native_poll_id then
        pcall(GLib.source_remove, text_popup._native_poll_id)
        text_popup._native_poll_id = nil
    end
    if qwen_native and qwen_native.stop_selection_hook then
        pcall(qwen_native.stop_selection_hook)
    end
    if text_popup._proximity_timer then
        pcall(GLib.source_remove, text_popup._proximity_timer)
        text_popup._proximity_timer = nil
    end
    if text_popup.watcher_sub_p then
        pcall(function() text_popup.watcher_sub_p:force_exit() end)
        text_popup.watcher_sub_p = nil
    end
    if text_popup.watcher_sub_c then
        pcall(function() text_popup.watcher_sub_c:force_exit() end)
        text_popup.watcher_sub_c = nil
    end
    text_popup.hide()
    collectgarbage("step", 100)
end

config.add_listener(function(key)
    if key == "global_text_menu" or (config.skills and key == "skills") then
        if config.skills and config.skills.global_text_menu == false then
            text_popup.stop_watcher()
        else
            text_popup.start_watcher()
        end
    end
end)

return text_popup
