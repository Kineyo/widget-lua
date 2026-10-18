----------------------------------------------------------------------
-- lib/skills/writing.lua  –  Habilidades de Escritura y Gramatica
--                            Impulsadas por llama.cpp (es-grammar.gguf)
--                            y API Cloud nativa. Cero emojis.
----------------------------------------------------------------------
local config    = require("config")
local ai_engine = require("ai_engine")

local writing = {}

writing.actions = {
    {
        id          = "skill_grammar",
        name        = "grammar",
        label       = "Corregir Gramatica",
        short_label = "Corregir Gramatica",
        instruction = "Corrige la sintaxis, concordancia gramatical, tildes y puntuacion del texto en espanol",
    },
    {
        id          = "skill_spelling",
        name        = "spelling",
        label       = "Mejorar Ortografia",
        short_label = "Mejorar Ortografia",
        instruction = "Corrige minuciosamente todas las faltas de ortografia, acentuacion y grafias dudosas en espanol",
    },
    {
        id          = "skill_formalize",
        name        = "formalize",
        label       = "Formalizar Texto",
        short_label = "Formalizar",
        instruction = "Convierte el siguiente texto a un tono formal, profesional, cortes y claro en espanol",
    },
    {
        id          = "skill_summarize",
        name        = "summarize",
        label       = "Resumir Texto",
        short_label = "Resumir",
        instruction = "Sintetiza y resume el texto extrayendo unicamente las ideas principales en espanol",
    },
    {
        id          = "skill_simplify",
        name        = "simplify",
        label       = "Simplificar y Clarificar",
        short_label = "Simplificar",
        instruction = "Simplifica y clarifica el texto haciendolo conciso, directo y facil de entender en espanol",
    },
    {
        id          = "skill_humanize",
        name        = "humanize",
        label       = "Humanizar Texto",
        short_label = "Humanizar",
        instruction = "Reescribe el texto para que suene totalmente natural, fluido y humano en espanol",
    },
    {
        id          = "skill_expand",
        name        = "expand",
        label       = "Desarrollar Ideas",
        short_label = "Alargar Texto",
        instruction = "Expande y enriquece este texto con mayor precision y desarrollo de ideas en espanol",
    },
}

function writing.get_action(id_or_name)
    for _, a in ipairs(writing.actions) do
        if a.id == id_or_name or a.name == id_or_name or a.label == id_or_name or a.short_label == id_or_name then
            return a
        end
    end
    return nil
end

function writing.get_enabled_actions()
    local list = {}
    for _, a in ipairs(writing.actions) do
        if not config.skills or config.skills[a.id] ~= false then
            list[#list + 1] = a
        end
    end
    return list
end

function writing.transform(action_id, input_text, callback)
    local act = writing.get_action(action_id)
    if not act then
        if callback then callback(false, "Accion gramatical no encontrada") end
        return
    end

    if config.skills and config.skills[act.id] == false then
        if callback then callback(false, "Esta habilidad esta desactivada en configuracion") end
        return
    end

    local clean_input = (input_text or ""):gsub("^%s*(.-)%s*$", "%1")
    if #clean_input == 0 then
        if callback then callback(false, "Texto de entrada vacio") end
        return
    end

    ai_engine.transform_text(act.instruction, clean_input, function(ok, res)
        if callback then callback(ok, res) end
        collectgarbage("step", 80)
    end)
end

return writing
