----------------------------------------------------------------------
-- animator.lua  –  Lightweight tween engine using GLib timers
----------------------------------------------------------------------
local lgi  = require("lgi")
local GLib = lgi.GLib

local config = require("config")
local utils  = require("utils")

local animator = {}

-- Track active fade animations per GTK window to prevent concurrent fighting/flicker
local active_fades = {}

----------------------------------------------------------------------
-- Stop any ongoing animation for a specific window
----------------------------------------------------------------------
function animator.stop(widget_window)
    if widget_window and active_fades[widget_window] then
        active_fades[widget_window]:stop()
        active_fades[widget_window] = nil
    end
end

----------------------------------------------------------------------
-- An Animation object holds state for a single 0→1 tween.
--   on_update(t)   – called each frame with eased t ∈ [0,1]
--   on_complete()  – called once when t reaches 1.0
----------------------------------------------------------------------
function animator.new(opts)
    local anim = {
        duration   = (opts.duration or config.FADE_DURATION_MS) / 1000,
        on_update  = opts.on_update  or function() end,
        on_complete= opts.on_complete or function() end,
        ease       = opts.ease or utils.ease_out,
        running    = false,
        forward    = true,        -- true = 0→1, false = 1→0
        value      = 0,           -- current raw progress
        timer_id   = nil,
    }

    local frame_ms = math.floor(1000 / (config.ANIM_FPS or 60))
    local dt = frame_ms / 1000

    function anim:start(forward)
        if forward ~= nil then self.forward = forward end
        if self.running then return end
        self.running = true
        self.timer_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, frame_ms, function()
            if not self.running then
                self.timer_id = nil
                return false
            end
            if self.forward then
                self.value = self.value + dt / self.duration
                if self.value >= 1.0 then
                    self.value = 1.0
                    self.running = false
                    self.timer_id = nil
                    self.on_update(self.ease(1.0))
                    self.on_complete()
                    return false
                end
            else
                self.value = self.value - dt / self.duration
                if self.value <= 0.0 then
                    self.value = 0.0
                    self.running = false
                    self.timer_id = nil
                    self.on_update(self.ease(0.0))
                    self.on_complete()
                    return false
                end
            end
            self.on_update(self.ease(self.value))
            return true   -- keep timer alive
        end)
    end

    function anim:stop()
        self.running = false
        if self.timer_id then
            pcall(function() GLib.source_remove(self.timer_id) end)
            self.timer_id = nil
        end
    end

    function anim:reset(v)
        self:stop()
        self.value = v or 0
    end

    function anim:is_running()
        return self.running
    end

    return anim
end

----------------------------------------------------------------------
-- Convenience: fade widget opacity cleanly 0→1 or 1→0
-- Smoothly handles interruptions and avoids flicker/parpadeo
----------------------------------------------------------------------
function animator.fade(widget_window, direction, callback, duration_override)
    if not widget_window then return nil end

    -- Stop any existing fade on this window immediately
    animator.stop(widget_window)

    local target_op = (direction == "in") and 1.0 or 0.0
    local cur_op = widget_window:get_opacity()
    if cur_op ~= cur_op or cur_op == nil then
        cur_op = (direction == "in") and 0.0 or 1.0
    end

    local start_op = cur_op
    if direction == "in" and start_op >= 1.0 then
        start_op = 0.0
    elseif direction == "out" and start_op <= 0.0 then
        start_op = 1.0
    end
    widget_window:set_opacity(start_op)

    local dist = math.abs(target_op - start_op)
    if dist < 0.02 then
        widget_window:set_opacity(target_op)
        if callback then callback() end
        return nil
    end

    local base_dur = duration_override or config.FADE_DURATION_MS or 220
    local dur = math.max(60, math.floor(base_dur * dist))

    local anim
    anim = animator.new({
        duration = dur,
        ease     = utils.ease_out,
        on_update = function(t)
            local op = utils.lerp(start_op, target_op, t)
            widget_window:set_opacity(op)
        end,
        on_complete = function()
            widget_window:set_opacity(target_op)
            active_fades[widget_window] = nil
            if callback then callback() end
        end,
    })

    anim.value = 0
    anim.forward = true
    active_fades[widget_window] = anim
    anim:start()
    return anim
end

return animator
