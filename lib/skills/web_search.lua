----------------------------------------------------------------------
-- lib/skills/web_search.lua  –  Habilidad de Busqueda Web (Cero Emojis)
----------------------------------------------------------------------
local base = require("skills.base")
local json = require("json")

local skill = {
    name = "web_search",
    description = "Busca informacion rapida en la web mediante DuckDuckGo Instant Answers.",
    params = { query = "string de busqueda" },
}

function skill.run(args, callback)
    local q = type(args) == "table" and (args.query or args.q) or tostring(args)
    if not q or #q == 0 then
        callback(false, "Consulta vacia")
        return
    end

    local encoded = q:gsub("[^%w _~%.%-]", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+")

    local url = "https://api.duckduckgo.com/?q=" .. encoded .. "&format=json&no_html=1&skip_disambig=1"
    base.exec_command(string.format("curl -s -m 8 '%s'", url), function(ok, body)
        if ok and body and #body > 0 then
            local ok_d, d = pcall(json.decode, body)
            if ok_d and d then
                local answer = d.Answer and #d.Answer > 0 and d.Answer or nil
                local abstract = d.AbstractText and #d.AbstractText > 0 and d.AbstractText or nil
                local source_url = d.AbstractURL or nil

                if answer or abstract then
                    local out = string.format("**[Busqueda Web: %s]**\n%s\n%s",
                        q, answer or abstract, source_url and ("Fuente: " .. source_url) or "")
                    callback(true, out)
                    return
                end
            end
        end

        local fallback_url = "https://html.duckduckgo.com/html/?q=" .. encoded
        base.exec_command(string.format("curl -s -m 8 -A 'Mozilla/5.0' '%s' | grep -o -E '<a class=\"result__snippet[^\"]*\">[^<]*' | head -n 3 | sed -e 's/<[^>]*>//g'", fallback_url), function(f_ok, f_out)
            if f_ok and f_out and #f_out > 0 then
                callback(true, string.format("**[Resultados Web: %s]**\n%s", q, f_out))
            else
                callback(true, string.format("[Busqueda Web] No se encontraron resultados directos para: *%s*", q))
            end
        end, 25, 10)
    end, 25, 10)
end

return skill
