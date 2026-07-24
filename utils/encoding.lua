local M = {}
function M.base64_encode(str)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    local len = #str
    local i = 1
    while i <= len do
        local b1 = str:byte(i, i) or 0
        local b2 = str:byte(i + 1, i + 1) or 0
        local b3 = str:byte(i + 2, i + 2) or 0
        local s1 = math.floor(b1 / 4)
        local s2 = ((b1 % 4) * 16) + math.floor(b2 / 16)
        local s3 = ((b2 % 16) * 4) + math.floor(b3 / 64)
        local s4 = b3 % 64
        table.insert(out, chars:sub(s1 + 1, s1 + 1))
        table.insert(out, chars:sub(s2 + 1, s2 + 1))
        table.insert(out, chars:sub(s3 + 1, s3 + 1))
        table.insert(out, chars:sub(s4 + 1, s4 + 1))
        i = i + 3
    end
    local remainder = len % 3
    if remainder == 1 then
        out[#out] = "="
        out[#out - 1] = "="
    elseif remainder == 2 then
        out[#out] = "="
    end
    return table.concat(out)
end
function M.escape_json_string(str)
    if type(str) ~= "string" then return tostring(str) end
    str = str:gsub("\\", "\\\\")
    str = str:gsub('"', '\\"')
    str = str:gsub("\n", "\\n")
    str = str:gsub("\r", "\\r")
    str = str:gsub("\t", "\\t")
    str = str:gsub("\b", "\\b")
    str = str:gsub("\f", "\\f")
    local out = {}
    for i = 1, #str do
        local byte = string.byte(str, i)
        if byte >= 0 and byte <= 31 then
            table.insert(out, string.format("\\u%04x", byte))
        else
            table.insert(out, string.sub(str, i, i))
        end
    end
    return table.concat(out)
end
function M.sanitize_for_json(str)
    if type(str) ~= "string" then return tostring(str) end
    -- Remove null bytes first (Lua gsub doesn't match \0, so we iterate)
    local cleaned = {}
    for i = 1, #str do
        local b = string.byte(str, i)
        if b ~= 0 then table.insert(cleaned, string.char(b)) end
    end
    str = table.concat(cleaned)
    local out = {}
    local i = 1
    while i <= #str do
        local byte = string.byte(str, i)
        if byte <= 0x1F then
            -- Control characters (0x01-0x1F): escape as \uXXXX
            table.insert(out, string.format("\\u%04x", byte))
            i = i + 1
        elseif byte <= 0x7F then
            -- Normal ASCII printable characters (0x20-0x7F)
            table.insert(out, string.char(byte))
            i = i + 1
        elseif byte >= 0xC2 and byte <= 0xDF then
            if i + 1 <= #str and string.byte(str, i + 1) >= 0x80 and string.byte(str, i + 1) <= 0xBF then
                table.insert(out, string.sub(str, i, i + 1))
                i = i + 2
            else
                table.insert(out, "?")
                i = i + 1
            end
        elseif byte >= 0xE0 and byte <= 0xEF then
            if i + 2 <= #str and string.byte(str, i + 1) >= 0x80 and string.byte(str, i + 1) <= 0xBF and string.byte(str, i + 2) >= 0x80 and string.byte(str, i + 2) <= 0xBF then
                table.insert(out, string.sub(str, i, i + 2))
                i = i + 3
            else
                table.insert(out, "?")
                i = i + 1
            end
        elseif byte >= 0xF0 and byte <= 0xF4 then
            if i + 3 <= #str and string.byte(str, i + 1) >= 0x80 and string.byte(str, i + 1) <= 0xBF and string.byte(str, i + 2) >= 0x80 and string.byte(str, i + 2) <= 0xBF and string.byte(str, i + 3) >= 0x80 and string.byte(str, i + 3) <= 0xBF then
                table.insert(out, string.sub(str, i, i + 3))
                i = i + 4
            else
                table.insert(out, "?")
                i = i + 1
            end
        else
            table.insert(out, "?")
            i = i + 1
        end
    end
    return table.concat(out)
end
return M