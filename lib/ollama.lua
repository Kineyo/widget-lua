-- ============================================================================
-- lib/ollama.lua - Compatibility Facade Redirecting to lib/ai_engine.lua
-- All inference is powered by embedded llama.cpp or native Cloud APIs.
-- ============================================================================

local ai_engine = require("ai_engine")

local M = {}

function M.send(user_text, on_token, on_error)
    return ai_engine.send(user_text, on_token, on_error)
end

function M.clear()
    return ai_engine.clear()
end

function M.cancel()
    return ai_engine.cancel()
end

function M.chat(messages, opts, callback)
    return ai_engine.chat(messages, opts, callback)
end

return M
