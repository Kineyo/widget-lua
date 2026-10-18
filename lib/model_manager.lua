-- ============================================================================
-- lib/model_manager.lua - Native GGUF Model Manager & Auto-Downloader
-- Preconfigured models:
--   1. Grammar Correction: es-grammar.gguf
--   2. Conversational Chat: qwen3.0-0.8b.gguf
-- Verifies GGUF magic headers and downloads missing models on install/first run
-- ============================================================================

local lgi  = require("lgi")
local GLib = lgi.require("GLib", "2.0")
local Gio  = lgi.require("Gio", "2.0")

local ok_native, qwen_native = pcall(require, "qwen_native")
if not ok_native then qwen_native = nil end

local M = {}

local BASE_DIR = (debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./") .. "../"
local MODELS_DIR = BASE_DIR .. "models"

M.DEFAULT_MODELS = {
    grammar = {
        id       = "es-grammar",
        filename = "es-grammar.gguf",
        label    = "ES-Grammar (Corrector Gramatical GGUF)",
        min_mb   = 150,
        url      = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
    },
    chat = {
        id       = "qwen3.0-0.8b",
        filename = "qwen3.0-0.8b.gguf",
        label    = "Qwen 3.0 0.8B (Chat Conversacional GGUF)",
        min_mb   = 200,
        url      = "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf",
    },
}

local active_downloads = {}

function M.get_models_dir()
    GLib.mkdir_with_parents(MODELS_DIR, 493) -- 0755
    return MODELS_DIR
end

function M.get_model_path(filename_or_role)
    local dir = M.get_models_dir()
    if M.DEFAULT_MODELS[filename_or_role] then
        return dir .. "/" .. M.DEFAULT_MODELS[filename_or_role].filename
    end
    if filename_or_role:match("^/") then
        return filename_or_role
    end
    return dir .. "/" .. filename_or_role
end

-- Verify GGUF file existence, minimum size, and "GGUF" magic header
function M.verify_model(filepath)
    if qwen_native and qwen_native.verify_gguf then
        local ok, info = qwen_native.verify_gguf(filepath)
        return ok, info
    end
    local f = io.open(filepath, "rb")
    if not f then
        return false, "Archivo no encontrado"
    end
    local magic = f:read(4)
    local sz = f:seek("end") or 0
    f:close()
    if magic ~= "GGUF" then
        return false, "Encabezado GGUF invalido"
    end
    local mb = sz / (1024 * 1024)
    if mb < 10 then
        return false, "Archivo truncado o incompleto"
    end
    return true, mb
end

function M.status()
    local res = {}
    for role, spec in pairs(M.DEFAULT_MODELS) do
        local path = M.get_model_path(spec.filename)
        local ok, mb_or_err = M.verify_model(path)
        res[role] = {
            id          = spec.id,
            filename    = spec.filename,
            label       = spec.label,
            path        = path,
            ready       = ok,
            size_mb     = ok and mb_or_err or 0,
            error       = (not ok) and tostring(mb_or_err) or nil,
            downloading = active_downloads[spec.filename] == true,
        }
    end
    return res
end

-- Asynchronous non-blocking download with progress callback and integrity check
function M.download_model(role_or_spec, on_progress, on_complete)
    local spec = type(role_or_spec) == "table" and role_or_spec or M.DEFAULT_MODELS[role_or_spec]
    if not spec then
        if on_complete then on_complete(false, "Especificacion de modelo desconocida") end
        return
    end

    local dest = M.get_model_path(spec.filename)
    local ok_already, sz_mb = M.verify_model(dest)
    if ok_already then
        if on_progress then on_progress(100, string.format("%s listo (%.1f MB)", spec.filename, sz_mb)) end
        if on_complete then on_complete(true, dest) end
        return
    end

    if active_downloads[spec.filename] then
        return
    end
    active_downloads[spec.filename] = true

    local part_path = dest .. ".part"
    local argv = {
        "curl", "-L", "--fail", "--retry", "3", "--retry-delay", "2",
        "-o", part_path, spec.url
    }

    local ok_sub, proc = pcall(function()
        return Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDERR_PIPE)
    end)

    if not ok_sub or not proc then
        active_downloads[spec.filename] = false
        if on_complete then on_complete(false, "No se pudo iniciar curl para descargar " .. spec.filename) end
        return
    end

    -- Monitor file growth periodically without blocking UI
    local poll_id
    poll_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 400, function()
        if not active_downloads[spec.filename] then
            return false
        end
        local f = io.open(part_path, "rb")
        if f then
            local bytes = f:seek("end") or 0
            f:close()
            local mb = bytes / (1024 * 1024)
            local est_total = (spec.min_mb or 350) * 1.15
            local pct = math.min(99, math.floor((mb / est_total) * 100))
            if on_progress then
                on_progress(pct, string.format("Descargando %s (%.1f MB)...", spec.filename, mb))
            end
        end
        return true
    end)

    proc:wait_async(nil, function(p, res)
        active_downloads[spec.filename] = false
        if poll_id then
            pcall(GLib.source_remove, poll_id)
            poll_id = nil
        end

        local ok_wait = pcall(function() p:wait_check_finish(res) end)
        if not ok_wait then
            os.remove(part_path)
            if on_complete then on_complete(false, "Error de red al descargar " .. spec.filename) end
            return
        end

        local valid, vinfo = M.verify_model(part_path)
        if not valid then
            os.remove(part_path)
            if on_complete then on_complete(false, "Verificacion GGUF fallida: " .. tostring(vinfo)) end
            return
        end

        os.rename(part_path, dest)
        if on_progress then
            on_progress(100, string.format("%s verificado (%.1f MB)", spec.filename, vinfo))
        end
        if on_complete then on_complete(true, dest) end
    end)
end

-- Ensure both default models (es-grammar and qwen3.0-0.8b) are present
function M.ensure_defaults(on_progress, on_all_done)
    local st = M.status()
    if st.grammar.ready and st.chat.ready then
        if on_all_done then on_all_done(true) end
        return
    end

    local function check_second()
        M.download_model("chat", on_progress, function(ok2, err2)
            if on_all_done then on_all_done(ok2, err2) end
        end)
    end

    if not st.grammar.ready then
        M.download_model("grammar", on_progress, function(ok1, err1)
            if not ok1 then
                if on_all_done then on_all_done(false, err1) end
                return
            end
            check_second()
        end)
    else
        check_second()
    end
end

return M
