----------------------------------------------------------------------
-- ollama.lua  –  Streaming client for Ollama /api/chat
----------------------------------------------------------------------
local lgi  = require("lgi")
local Gio  = lgi.Gio
local GLib = lgi.GLib

local config = require("config")
local json   = require("json")

local ollama = {}

-- Conversation history (kept in memory, capped)
ollama.history    = {}
ollama.MAX_HIST   = 40     -- max messages to keep in context
ollama.streaming  = false  -- true while a response is being generated
ollama.cancel_sub = nil    -- Gio.Subprocess of active request (to cancel)

----------------------------------------------------------------------
-- Add a message to history
----------------------------------------------------------------------
function ollama.init_system_prompt()
    if #ollama.history == 0 then
        local ok, agent = pcall(require, "openclaw_agent")
        if ok and agent and agent.get_system_prompt then
            table.insert(ollama.history, 1, { role = "system", content = agent.get_system_prompt() })
        end
    end
end

function ollama.push(role, content)
    ollama.init_system_prompt()
    ollama.history[#ollama.history+1] = { role = role, content = content }
    -- Trim oldest if over limit (always keep system prompt if present)
    while #ollama.history > ollama.MAX_HIST do
        if #ollama.history > 1 and ollama.history[1].role == "system" then
            table.remove(ollama.history, 2)
        else
            table.remove(ollama.history, 1)
        end
    end
end

----------------------------------------------------------------------
-- Clear history
----------------------------------------------------------------------
function ollama.clear()
    ollama.history = {}
    ollama.init_system_prompt()
end

----------------------------------------------------------------------
-- Cancel any in-flight request
----------------------------------------------------------------------
function ollama.cancel()
    if ollama.cancel_sub then
        pcall(function() ollama.cancel_sub:force_exit() end)
        ollama.cancel_sub = nil
    end
    ollama.streaming = false
end

----------------------------------------------------------------------
-- Send a user message; stream tokens back via on_token(text, done).
-- on_error(msg) called if something goes wrong.
----------------------------------------------------------------------
function ollama.send(user_msg, on_token, on_error)
    if ollama.streaming then
        if on_error then on_error("Ya hay una respuesta en curso") end
        return
    end

    -- Add user message
    ollama.push("user", user_msg)

    -- Build request body
    local body = json.encode({
        model    = config.OLLAMA_MODEL,
        messages = ollama.history,
        stream   = true,
    })

    -- Spawn curl with POST
    local ok, sub = pcall(Gio.Subprocess.new,
        {
            "curl", "-s", "-m", "120",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", body,
            config.OLLAMA_URL,
        },
        Gio.SubprocessFlags.STDOUT_PIPE + Gio.SubprocessFlags.STDERR_SILENCE)

    if not ok or not sub then
        if on_error then on_error("No se pudo conectar a Ollama") end
        return
    end

    ollama.streaming  = true
    ollama.cancel_sub = sub

    -- Read stdout stream line by line
    local stdout = sub:get_stdout_pipe()
    local stream = Gio.DataInputStream.new(stdout)

    local full_response = {}

    local function read_next_line()
        stream:read_line_async(GLib.PRIORITY_DEFAULT, nil, function(src, result)
            local line, _ = src:read_line_finish(result)
            if line == nil then
                -- Stream ended
                ollama.streaming  = false
                ollama.cancel_sub = nil
                local full = table.concat(full_response)
                if #full > 0 then
                    ollama.push("assistant", full)
                end
                if on_token then on_token("", true) end
                return
            end

            -- line is a GLib.Bytes or string; normalise
            local str = type(line) == "string" and line or tostring(line)
            if #str > 0 then
                local d = json.decode(str)
                if d then
                    if d.message and d.message.content then
                        local token = d.message.content
                        full_response[#full_response+1] = token
                        if on_token then on_token(token, false) end
                    end
                    if d.done then
                        ollama.streaming  = false
                        ollama.cancel_sub = nil
                        local full = table.concat(full_response)
                        if #full > 0 then
                            ollama.push("assistant", full)
                        end
                        if on_token then on_token("", true) end
                        return  -- stop reading
                    end
                    if d.error then
                        ollama.streaming = false
                        if on_error then on_error(d.error) end
                        return
                    end
                end
            end

            -- Continue reading
            read_next_line()
        end)
    end

    read_next_line()
end

return ollama
