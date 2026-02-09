-- utils.lua
local M = {}
local io = require("io")

function M.read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    local ok, w_err = f:write(content)
    f:close()
    if not ok then return false, w_err end
    return true
end

function M.trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- == CONTEXT MAPPER ==
-- Эвристический парсер для создания "карты" файла (экономия токенов)
function M.get_file_outline(path)
    local content, err = M.read_file(path)
    if not content then return "Error reading file: " .. tostring(err) end

    local outline = {}
    local line_num = 0
    
    -- Простые паттерны для Lua, Python, JS, C
    -- Это "Dirty Hack", но работает быстрее чем полноценный AST парсер
    for line in content:gmatch("[^\r\n]+") do
        line_num = line_num + 1
        local clean_line = M.trim(line)
        
        -- Ловим определения функций, классов, экспорты
        if clean_line:match("^function") or 
           clean_line:match("^local%s+function") or
           clean_line:match("^class") or
           clean_line:match("^def%s") or -- python
           clean_line:match("^export") or
           clean_line:match("M%..-%s=") then
            
            table.insert(outline, string.format("%03d: %s", line_num, clean_line))
        end
    end

    if #outline == 0 then
        return "(No structural definitions found. File might be flat script or text.)"
    end
    
    return table.concat(outline, "\n")
end

function M.list_files_recursive(root_path)
    -- Используем чистый `find` для совместимости, rg опционален
    -- Исключаем git и прочий мусор
    local cmd = string.format("find '%s' -type f -not -path '*/.*' -not -path '*/node_modules/*' -not -path '*/lua_modules/*' 2>/dev/null", root_path)
    
    local p = io.popen(cmd)
    if not p then return "Error: find command failed" end
    
    local output = p:read("*a")
    p:close()

    local files = {}
    local limit = 200
    local count = 0
    
    for line in output:gmatch("[^\r\n]+") do
        -- Убираем префикс ./
        local clean_path = line:gsub("^%./", ""):gsub("^"..root_path.."/?", "")
        if clean_path ~= "" then
            count = count + 1
            if count <= limit then
                table.insert(files, clean_path)
            end
        end
    end
    
    local res = table.concat(files, "\n")
    if count > limit then
        res = res .. "\n... [TRUNCATED " .. (count - limit) .. " files]"
    end
    return res
end

return M
