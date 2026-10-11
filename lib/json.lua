----------------------------------------------------------------------
-- json.lua  –  Minimal JSON encoder / decoder (pure Lua, no deps)
-- Only handles the subset we need: objects, arrays, strings,
-- numbers, booleans, null (mapped to json.null sentinel).
----------------------------------------------------------------------
local json = {}

-- Sentinel for JSON null
json.null = setmetatable({}, { __tostring = function() return "null" end })

----------------------------------------------------------------------
-- DECODER
----------------------------------------------------------------------
local function skip_ws(s, i)
    return s:match("^%s*()", i)
end

local function decode_string(s, i)
    -- i points to the opening "
    i = i + 1
    local parts = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(parts), i + 1
        elseif c == '\\' then
            i = i + 1
            local esc = s:sub(i, i)
            if     esc == '"'  then parts[#parts+1] = '"'
            elseif esc == '\\' then parts[#parts+1] = '\\'
            elseif esc == '/'  then parts[#parts+1] = '/'
            elseif esc == 'n'  then parts[#parts+1] = '\n'
            elseif esc == 'r'  then parts[#parts+1] = '\r'
            elseif esc == 't'  then parts[#parts+1] = '\t'
            elseif esc == 'b'  then parts[#parts+1] = '\b'
            elseif esc == 'f'  then parts[#parts+1] = '\f'
            elseif esc == 'u'  then
                local hex = s:sub(i+1, i+4)
                local cp = tonumber(hex, 16)
                if cp then
                    if cp < 0x80 then
                        parts[#parts+1] = string.char(cp)
                    elseif cp < 0x800 then
                        parts[#parts+1] = string.char(
                            0xC0 + math.floor(cp / 64),
                            0x80 + (cp % 64))
                    else
                        parts[#parts+1] = string.char(
                            0xE0 + math.floor(cp / 4096),
                            0x80 + math.floor((cp % 4096) / 64),
                            0x80 + (cp % 64))
                    end
                end
                i = i + 4
            end
            i = i + 1
        else
            parts[#parts+1] = c
            i = i + 1
        end
    end
    error("json: unterminated string")
end

local decode_value  -- forward declaration

local function decode_object(s, i)
    i = i + 1 -- skip {
    local obj = {}
    i = skip_ws(s, i)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
        i = skip_ws(s, i)
        if s:sub(i, i) ~= '"' then error("json: expected string key at " .. i) end
        local key
        key, i = decode_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then error("json: expected ':' at " .. i) end
        i = skip_ws(s, i + 1)
        local val
        val, i = decode_value(s, i)
        obj[key] = val
        i = skip_ws(s, i)
        local sep = s:sub(i, i)
        if sep == '}' then return obj, i + 1 end
        if sep ~= ',' then error("json: expected ',' or '}' at " .. i) end
        i = i + 1
    end
end

local function decode_array(s, i)
    i = i + 1 -- skip [
    local arr = {}
    i = skip_ws(s, i)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
        i = skip_ws(s, i)
        local val
        val, i = decode_value(s, i)
        arr[#arr+1] = val
        i = skip_ws(s, i)
        local sep = s:sub(i, i)
        if sep == ']' then return arr, i + 1 end
        if sep ~= ',' then error("json: expected ',' or ']' at " .. i) end
        i = i + 1
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decode_string(s, i)
    elseif c == '{' then return decode_object(s, i)
    elseif c == '[' then return decode_array(s, i)
    elseif c == 't' then
        if s:sub(i, i+3) == 'true' then return true, i+4 end
    elseif c == 'f' then
        if s:sub(i, i+4) == 'false' then return false, i+5 end
    elseif c == 'n' then
        if s:sub(i, i+3) == 'null' then return json.null, i+4 end
    else
        -- number
        local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if num_str then
            return tonumber(num_str), i + #num_str
        end
    end
    error("json: unexpected character '" .. c .. "' at position " .. i)
end

function json.decode(s)
    if type(s) ~= "string" or #s == 0 then return nil end
    local ok, val, _ = pcall(decode_value, s, 1)
    if ok then return val end
    return nil
end

----------------------------------------------------------------------
-- ENCODER
----------------------------------------------------------------------
local encode_value  -- forward

local function encode_string(s)
    s = s:gsub('\\', '\\\\')
         :gsub('"', '\\"')
         :gsub('\n', '\\n')
         :gsub('\r', '\\r')
         :gsub('\t', '\\t')
    return '"' .. s .. '"'
end

encode_value = function(v)
    local t = type(v)
    if v == json.null then return "null"
    elseif t == "nil"     then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number"  then return tostring(v)
    elseif t == "string"  then return encode_string(v)
    elseif t == "table"   then
        -- Detect array vs object: array if sequential integer keys 1..n
        local n = #v
        local is_array = (n > 0)
        if is_array then
            for k, _ in pairs(v) do
                if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
                    is_array = false
                    break
                end
            end
        end
        -- Also treat empty table as object {}
        if is_array then
            local parts = {}
            for i = 1, n do
                parts[i] = encode_value(v[i])
            end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local parts = {}
            for k, val in pairs(v) do
                if type(k) == "string" then
                    parts[#parts+1] = encode_string(k) .. ':' .. encode_value(val)
                end
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return "null"
end

function json.encode(v)
    return encode_value(v)
end

return json
