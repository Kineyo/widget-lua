----------------------------------------------------------------------
-- chat.lua  –  Floating chat panel with OpenClaw Agent Skills & Controls
----------------------------------------------------------------------
local lgi    = require("lgi")
local Gtk    = lgi.require("Gtk", "3.0")
local Gdk    = lgi.require("Gdk", "3.0")
local GLib   = lgi.GLib
local Pango  = lgi.Pango
local cairo  = lgi.cairo

local config   = require("config")
local utils    = require("utils")
local ollama   = require("ollama")
local animator = require("animator")
local openclaw = require("openclaw_agent")
local player   = require("player")
local mpris    = require("mpris")

local chat = {}

chat.window          = nil
chat.visible         = false
chat.textview        = nil
chat.entry           = nil
chat.scroll          = nil
chat.buffer          = nil
chat.status_label    = nil
chat.model_label     = nil
chat.on_invoke_bubble = nil

-- Parent bubble info for positioning mini player
local last_bx, last_by = 0, 0
local last_bsize = config.BUBBLE_SIZE
local last_edge = "right"

----------------------------------------------------------------------
-- CSS
----------------------------------------------------------------------
local CSS = [[
.chat-window {
    background-color: transparent;
}
.chat-scroll {
    background-color: transparent;
}
.chat-scroll scrollbar slider {
    background-color: rgba(139, 92, 246, 0.35);
    min-width: 5px;
    border-radius: 3px;
}
.chat-scroll scrollbar slider:hover {
    background-color: rgba(139, 92, 246, 0.70);
}
.chat-text {
    background-color: transparent;
    color: #F1F1FD;
    font-family: "Sans";
    font-size: 11.5px;
    padding: 8px 12px;
}
.chat-text text {
    background-color: transparent;
    color: #F1F1FD;
}
.chat-entry {
    background-color: rgba(24, 21, 38, 0.94);
    color: #F8FAFC;
    border: 1.2px solid rgba(139, 92, 246, 0.30);
    border-radius: 20px;
    padding: 7px 14px;
    font-family: "Sans";
    font-size: 11.5px;
    caret-color: #A78BFA;
}
.chat-entry:focus {
    border-color: #8B5CF6;
    background-color: rgba(28, 25, 46, 0.98);
}
.send-btn {
    background-color: #8B5CF6;
    color: #FFFFFF;
    border: none;
    border-radius: 50%;
    min-width: 30px;
    min-height: 30px;
    padding: 0;
    font-size: 12px;
    font-weight: bold;
}
.send-btn:hover {
    background-color: #A78BFA;
}
.chat-header {
    color: #FFFFFF;
    font-weight: bold;
    font-size: 12px;
}
.model-pill {
    background-color: rgba(139, 92, 246, 0.15);
    color: #C4B5FD;
    border: 1px solid rgba(139, 92, 246, 0.30);
    border-radius: 10px;
    padding: 1px 7px;
    font-size: 9.5px;
    font-weight: bold;
}
.status-label {
    color: #22D3EE;
    font-size: 10px;
    font-weight: 500;
}
.chat-close-btn {
    background-color: transparent;
    color: #94A3B8;
    border: none;
    border-radius: 50%;
    min-width: 22px;
    min-height: 22px;
    padding: 0;
    font-size: 11px;
}
.chat-close-btn:hover {
    color: #F87171;
    background-color: rgba(255, 255, 255, 0.08);
}
.toolbar-box {
    background-color: rgba(20, 18, 32, 0.65);
    border-radius: 12px;
    padding: 4px 8px;
    margin: 4px 12px;
    border: 1px solid rgba(255, 255, 255, 0.05);
}
.tool-btn {
    background-color: rgba(32, 28, 52, 0.60);
    color: #E2E8F0;
    border: 1px solid rgba(139, 92, 246, 0.20);
    border-radius: 12px;
    padding: 3px 9px;
    font-size: 9.5px;
    font-weight: 500;
}
.tool-btn:hover {
    background-color: rgba(139, 92, 246, 0.35);
    color: #FFFFFF;
    border-color: #A78BFA;
}
.tool-btn-accent {
    background-color: rgba(139, 92, 246, 0.22);
    color: #DDD6FE;
    border: 1px solid rgba(139, 92, 246, 0.35);
    border-radius: 12px;
    padding: 3px 9px;
    font-size: 9.5px;
    font-weight: 500;
}
.tool-btn-accent:hover {
    background-color: #8B5CF6;
    color: #FFFFFF;
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
-- Auto-scroll
----------------------------------------------------------------------
local function scroll_to_bottom()
    if not chat.scroll then return end
    GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
        local adj = chat.scroll:get_vadjustment()
        adj:set_value(adj:get_upper() - adj:get_page_size())
        return false
    end)
end

----------------------------------------------------------------------
-- Convert Markdown syntax to GTK Pango Markup for rich styling
-- Handles: **bold**, `code`, ```code blocks```, *italic*, headers, etc.
----------------------------------------------------------------------
local function md_to_pango(text)
    if not text or #text == 0 then return "" end

    -- 1. Escape XML characters
    local s = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    -- 2. Code blocks ```bash ... ```
    s = s:gsub("```[%w_%-]*\n?(.-)```", function(code)
        local clean = code:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
        return string.format(
            '<span font_family="Monospace" background="#141224" foreground="#22D3EE">\n  %s\n</span>',
            clean:gsub("\n", "\n  ")
        )
    end)

    -- 3. Inline code `code`
    s = s:gsub("`([^`\n]+)`", '<span font_family="Monospace" background="#242038" foreground="#FBBF24"> %1 </span>')

    -- 4. Bold: **text** or __text__ -> bright bold text
    s = s:gsub("%*%*([^\n%*]+)%*%*", '<span weight="bold" foreground="#FFFFFF">%1</span>')
    s = s:gsub("__([^\n_]+)__", '<span weight="bold" foreground="#FFFFFF">%1</span>')

    -- 5. Italic: *text* (when not part of **)
    s = s:gsub("(%f[%w*])%*([^\n%*]+)%*(%f[%W*])", '<span style="italic" foreground="#E0E0FF">%2</span>')

    -- 6. Markdown headers
    s = s:gsub("(^|\n)###%s+([^\n]+)", '%1<span weight="bold" foreground="#22D3EE">%2</span>')
    s = s:gsub("(^|\n)##%s+([^\n]+)", '%1<span weight="bold" size="larger" foreground="#A78BFA">%2</span>')
    s = s:gsub("(^|\n)#%s+([^\n]+)", '%1<span weight="bold" size="x-large" foreground="#F472B6">%2</span>')

    return s
end

local function style_prefix(prefix)
    if not prefix or #prefix == 0 then return "" end
    local p = prefix:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    if p:find("✦ Tú:") then
        p = p:gsub("✦ Tú:", '<span weight="bold" foreground="#F472B6">✦ Tú:</span>')
    elseif p:find("🦞 OpenClaw:") then
        p = p:gsub("🦞 OpenClaw:", '<span weight="bold" foreground="#C084FC">🦞 OpenClaw:</span>')
    elseif p:find("✧ Qwen %(OpenClaw%):") then
        p = p:gsub("✧ Qwen %(OpenClaw%):", '<span weight="bold" foreground="#A78BFA">✧ Qwen (OpenClaw):</span>')
    elseif p:find("⚡ %[OpenClaw Skill%]") then
        p = p:gsub("⚡ %[OpenClaw Skill%]", '<span weight="bold" foreground="#22D3EE">⚡ [OpenClaw Skill]</span>')
    elseif p:find("⚠ Error:") then
        p = p:gsub("⚠ Error:", '<span weight="bold" foreground="#F87171">⚠ Error:</span>')
    elseif p:find("↳") then
        p = p:gsub("↳", '<span foreground="#94A3B8">↳</span>')
    end

    return p
end

----------------------------------------------------------------------
-- Append formatted Markdown text to chat view
----------------------------------------------------------------------
local function append_colored(prefix, text)
    local buf = chat.buffer
    if not buf then return end

    local markup = style_prefix(prefix) .. md_to_pango(text)
    local iter = buf:get_end_iter()
    local ok = pcall(function()
        buf:insert_markup(iter, markup, -1)
    end)
    if not ok then
        iter = buf:get_end_iter()
        buf:insert(iter, (prefix or "") .. (text or ""), -1)
    end
    scroll_to_bottom()
end

----------------------------------------------------------------------
-- Send message (handles slash commands and agent tools)
----------------------------------------------------------------------
local function on_send()
    local text = chat.entry:get_text()
    if not text or #text:match("^%s*(.-)%s*$") == 0 then return end

    local clean_text = text:match("^%s*(.-)%s*$")
    chat.entry:set_text("")

    -- 1) Check Slash Command
    if clean_text:sub(1, 1) == "/" then
        append_colored("\n  ✦ Tú: ", clean_text .. "\n")
        local handled = openclaw.handle_slash_command(clean_text, function(res)
            GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
                append_colored("  🦞 OpenClaw:\n  ", res:gsub("\n", "\n  ") .. "\n")
                if chat.status_label then chat.status_label:set_text("✓ Listo") end
                chat.entry:grab_focus()
                return false
            end)
        end)
        if handled then return end
    end

    -- 2) Ollama Natural Language with OpenClaw Agent
    chat.entry:set_sensitive(false)
    if chat.send_btn then chat.send_btn:set_sensitive(false) end
    append_colored("\n  ✦ Tú: ", clean_text .. "\n")
    append_colored("  ✧ Qwen (OpenClaw): ", "")

    local response_chunks = {}
    local stream_start_offset = chat.buffer:get_char_count()

    ollama.send(clean_text,
        function(token, done)
            GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
                if done then
                    local full_resp = table.concat(response_chunks)

                    -- Replace raw streaming tokens with parsed highlighted Markdown
                    local iter_start = chat.buffer:get_iter_at_offset(stream_start_offset)
                    local iter_end = chat.buffer:get_end_iter()
                    chat.buffer:delete(iter_start, iter_end)

                    local iter_now = chat.buffer:get_end_iter()
                    local ok = pcall(function()
                        chat.buffer:insert_markup(iter_now, md_to_pango(full_resp .. "\n"), -1)
                    end)
                    if not ok then
                        chat.buffer:insert(iter_now, full_resp .. "\n", -1)
                    end
                    scroll_to_bottom()

                    -- Check if response contains an OpenClaw tool call
                    local tool_name, tool_args = openclaw.detect_tool_call(full_resp)
                    if tool_name then
                        append_colored("  ⚡ [OpenClaw Skill] ", string.format("Ejecutando: %s...\n", tool_name))
                        if chat.status_label then chat.status_label:set_text("⚡ Ejecutando: " .. tool_name) end

                        openclaw.execute(tool_name, tool_args, function(ok, res_str)
                            GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
                                append_colored("  ↳ ", res_str:gsub("\n", "\n  ") .. "\n")
                                chat.entry:set_sensitive(true)
                                if chat.send_btn then chat.send_btn:set_sensitive(true) end
                                chat.entry:grab_focus()
                                if chat.status_label then chat.status_label:set_text("✓ Listo") end
                                return false
                            end)
                        end)
                    else
                        chat.entry:set_sensitive(true)
                        if chat.send_btn then chat.send_btn:set_sensitive(true) end
                        chat.entry:grab_focus()
                        if chat.status_label then chat.status_label:set_text("✓ Listo") end
                    end
                else
                    response_chunks[#response_chunks+1] = token
                    local buf = chat.buffer
                    local iter = buf:get_end_iter()
                    buf:insert(iter, token, -1)
                    scroll_to_bottom()
                    if chat.status_label then chat.status_label:set_text("⟳ Pensando...") end
                end
                return false
            end)
        end,
        function(err)
            GLib.idle_add(GLib.PRIORITY_DEFAULT, function()
                append_colored("  ⚠ Error: ", tostring(err) .. "\n")
                chat.entry:set_sensitive(true)
                if chat.send_btn then chat.send_btn:set_sensitive(true) end
                chat.entry:grab_focus()
                if chat.status_label then chat.status_label:set_text("⚠ Error") end
                return false
            end)
        end)
end

----------------------------------------------------------------------
-- Build chat window
----------------------------------------------------------------------
function chat.build(parent_window)
    if chat.window then return end
    apply_css()

    local win = Gtk.Window {
        type = Gtk.WindowType.TOPLEVEL,
        decorated = false,
        skip_taskbar_hint = true,
        skip_pager_hint = true,
        resizable = false,
        accept_focus = true,
        type_hint = Gdk.WindowTypeHint.UTILITY,
        default_width  = config.CHAT_W,
        default_height = config.CHAT_H,
    }
    win:set_keep_above(true)
    win:get_style_context():add_class("chat-window")

    -- RGBA
    local screen = win:get_screen()
    local visual = screen:get_rgba_visual()
    if visual then win:set_visual(visual) end
    win:set_app_paintable(true)

    -- Draw rounded glassmorphic background
    win.on_draw = function(self, cr)
        local w = self:get_allocated_width()
        local h = self:get_allocated_height()
        local r = config.CHAT_RADIUS or 18

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
        cr:set_source_rgba(config.ACCENT[1], config.ACCENT[2], config.ACCENT[3], 0.35)
        cr:set_line_width(1.2)
        cr:stroke()

        return false
    end

    -- Layout
    local vbox = Gtk.Box { orientation = Gtk.Orientation.VERTICAL, spacing = 0 }

    -- Header
    local hbar = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL, spacing = 8,
        margin_start = 14, margin_end = 12,
        margin_top = 10, margin_bottom = 4,
    }

    -- Preserve icon in header
    local avatar_mini = utils.load_pixbuf(config.AVATAR, 20) or utils.load_pixbuf(config.ASSETS_DIR .. "/icon.png", 20)
    if avatar_mini then
        local img = Gtk.Image.new_from_pixbuf(avatar_mini)
        hbar:pack_start(img, false, false, 0)
    end

    local title = Gtk.Label { label = "✦ Qwen AI" }
    title:get_style_context():add_class("chat-header")
    hbar:pack_start(title, false, false, 0)

    chat.model_label = Gtk.Label { label = config.OLLAMA_MODEL }
    chat.model_label:get_style_context():add_class("model-pill")
    hbar:pack_start(chat.model_label, false, false, 0)

    hbar:pack_start(Gtk.Label { label = "" }, true, true, 0)

    chat.status_label = Gtk.Label { label = "● En línea" }
    chat.status_label:get_style_context():add_class("status-label")
    hbar:pack_end(chat.status_label, false, false, 0)

    local close_btn = Gtk.Button { label = "✕" }
    close_btn:get_style_context():add_class("chat-close-btn")
    close_btn:set_tooltip_text("Cerrar chat (Esc)")
    close_btn.on_clicked = function() chat.hide() end
    hbar:pack_end(close_btn, false, false, 4)

    vbox:pack_start(hbar, false, false, 0)

    -- OpenClaw Action Toolbar
    local action_bar = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL,
        spacing = 6,
    }
    action_bar:get_style_context():add_class("toolbar-box")

    local btn_bubble = Gtk.Button { label = "💡 Burbuja" }
    btn_bubble:get_style_context():add_class("tool-btn-accent")
    btn_bubble:set_tooltip_text("Invocar burbuja de datos e info en el widget")
    btn_bubble.on_clicked = function()
        if chat.on_invoke_bubble then
            chat.on_invoke_bubble()
        end
    end
    action_bar:pack_start(btn_bubble, false, false, 0)

    local btn_player = Gtk.Button { label = "🎵 Música" }
    btn_player:get_style_context():add_class("tool-btn")
    btn_player:set_tooltip_text("Desplegar mini reproductor de YouTube Music")
    btn_player.on_clicked = function()
        player.toggle(last_bx, last_by, last_bsize, last_edge)
    end
    action_bar:pack_start(btn_player, false, false, 0)

    local btn_sys = Gtk.Button { label = "📊 Sistema" }
    btn_sys:get_style_context():add_class("tool-btn")
    btn_sys:set_tooltip_text("Diagnóstico de CPU, RAM y almacenamiento")
    btn_sys.on_clicked = function()
        openclaw.handle_slash_command("/sys", function(res)
            append_colored("\n  ✦ Tú: /sys\n  🦞 OpenClaw:\n  ", res:gsub("\n", "\n  ") .. "\n")
        end)
    end
    action_bar:pack_start(btn_sys, false, false, 0)

    action_bar:pack_start(Gtk.Label { label = "" }, true, true, 0)

    local btn_clear = Gtk.Button { label = "🧹 Limpiar" }
    btn_clear:get_style_context():add_class("tool-btn")
    btn_clear:set_tooltip_text("Limpiar historial de conversación")
    btn_clear.on_clicked = function()
        ollama.clear()
        if chat.buffer then
            chat.buffer:set_text("", 0)
            local it = chat.buffer:get_end_iter()
            local reset_msg = md_to_pango("  ✦ **Historial reiniciado.**\n  Escribe un mensaje o usa `/help` para comandos.\n")
            pcall(function() chat.buffer:insert_markup(it, reset_msg, -1) end)
        end
    end
    action_bar:pack_end(btn_clear, false, false, 0)

    vbox:pack_start(action_bar, false, false, 0)

    local sep = Gtk.Separator { orientation = Gtk.Orientation.HORIZONTAL }
    sep:set_opacity(0.12)
    vbox:pack_start(sep, false, false, 0)

    -- Chat history
    local sw = Gtk.ScrolledWindow {
        hscrollbar_policy = Gtk.PolicyType.NEVER,
        vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
    }
    sw:get_style_context():add_class("chat-scroll")

    local tv = Gtk.TextView {
        editable = false,
        cursor_visible = false,
        wrap_mode = Gtk.WrapMode.WORD_CHAR,
        left_margin = 8, right_margin = 8,
        top_margin = 6, bottom_margin = 6,
    }
    tv:get_style_context():add_class("chat-text")

    local buf = tv:get_buffer()

    -- Welcome text
    local iter = buf:get_end_iter()
    local welcome_md = "  ✦ **OpenClaw Qwen Assistant** ✦\n" ..
                       "  Agente inteligente en Pop!_OS con interfaz minimalista.\n" ..
                       "  • Clic en widget: Abrir / Ocultar chat\n" ..
                       "  • Clic derecho o botón '💡 Burbuja': Ver datos e info\n" ..
                       "  • Clic central o botón '🎵 Música': Mini reproductor\n" ..
                       "  Escribe un mensaje o usa `/help` para comandos.\n"
    local ok_w = pcall(function()
        buf:insert_markup(iter, md_to_pango(welcome_md), -1)
    end)
    if not ok_w then
        buf:insert(iter, welcome_md, -1)
    end

    sw:add(tv)
    vbox:pack_start(sw, true, true, 0)

    -- Input Box with Pill Entry and Send Button
    local input_box = Gtk.Box {
        orientation = Gtk.Orientation.HORIZONTAL, spacing = 8,
        margin_start = 12, margin_end = 12,
        margin_top = 6, margin_bottom = 12,
    }
    local entry = Gtk.Entry { placeholder_text = "Escribe un mensaje o /help..." }
    entry:get_style_context():add_class("chat-entry")
    entry.on_activate = function() on_send() end
    input_box:pack_start(entry, true, true, 0)

    local send_btn = Gtk.Button { label = "➤" }
    send_btn:get_style_context():add_class("send-btn")
    send_btn:set_tooltip_text("Enviar mensaje (Enter)")
    send_btn.on_clicked = function() on_send() end
    input_box:pack_end(send_btn, false, false, 0)
    chat.send_btn = send_btn

    vbox:pack_start(input_box, false, false, 0)

    win:add(vbox)

    chat.window   = win
    chat.textview = tv
    chat.entry    = entry
    chat.scroll   = sw
    chat.buffer   = buf

    win.on_key_press_event = function(self, event)
        if event.keyval == Gdk.KEY_Escape then
            chat.hide()
            return true
        end
        return false
    end

    win.on_delete_event = function()
        chat.hide()
        return true
    end
end

local last_toggle_time = 0

----------------------------------------------------------------------
-- Position and show chat near the bubble
----------------------------------------------------------------------
function chat.show(bx, by, bsize, edge)
    chat.build()
    if not chat.window then return end

    chat.visible = true

    last_bx = bx or last_bx
    last_by = by or last_by
    last_bsize = bsize or last_bsize
    last_edge = edge or last_edge

    -- Hide any open speech bubble to prevent overlap
    local ok_b, bubbles = pcall(require, "bubbles")
    if ok_b and bubbles then bubbles.hide() end

    local screen = Gdk.Screen.get_default()
    local sw = screen:get_width()
    local sh = screen:get_height()
    local gap = config.CHAT_GAP or 10

    local cx, cy
    if last_edge == "left" then
        cx = last_bx + last_bsize + gap
        cy = last_by + last_bsize - config.CHAT_H
    elseif last_edge == "right" then
        cx = last_bx - config.CHAT_W - gap
        cy = last_by + last_bsize - config.CHAT_H
    elseif last_edge == "top" then
        cx = last_bx + (last_bsize - config.CHAT_W) / 2
        cy = last_by + last_bsize + gap
    else -- bottom
        cx = last_bx + (last_bsize - config.CHAT_W) / 2
        cy = last_by - config.CHAT_H - gap
    end

    -- Clamp
    cx = math.max(5, math.min(cx, sw - config.CHAT_W - 5))
    cy = math.max(5, math.min(cy, sh - config.CHAT_H - 5))

    if chat.model_label then
        chat.model_label:set_text(config.OLLAMA_MODEL)
    end

    chat.window:move(math.floor(cx), math.floor(cy))
    if not chat.window:get_visible() then
        chat.window:set_opacity(0)
        chat.window:show_all()
    end

    animator.fade(chat.window, "in", function()
        if chat.visible and chat.entry then
            chat.entry:grab_focus()
        end
    end)
end

----------------------------------------------------------------------
-- Hide
----------------------------------------------------------------------
function chat.hide(instant)
    if not chat.window then return end
    chat.visible = false
    ollama.cancel()

    if instant then
        animator.stop(chat.window)
        chat.window:set_opacity(0)
        chat.window:hide()
        return
    end

    animator.fade(chat.window, "out", function()
        if not chat.visible and chat.window then
            chat.window:hide()
            chat.window:set_opacity(0)
        end
    end)
end

----------------------------------------------------------------------
-- Toggle
----------------------------------------------------------------------
function chat.toggle(bx, by, bsize, edge)
    local now = GLib.get_monotonic_time() / 1000 -- ms
    if (now - last_toggle_time) < 150 then
        return
    end
    last_toggle_time = now

    if chat.visible then
        chat.hide()
    else
        chat.show(bx, by, bsize, edge)
    end
end

return chat
