-- utils.lua
local M = {}
local io = require("io")

-- === NEW: PATH RESOLVER ===
function M.resolve_relative_path(root, raw_path)
    -- Убираем лишние пробелы
    local p = M.trim(raw_path)
    
    -- Убираем точку в начале (./file -> file)
    p = p:gsub("^%./", "")
    
    -- Если путь начинается с корня проекта (абсолютный), обрезаем корень
    -- Экранируем спецсимволы в root для паттерна (-, ., и т.д.)
    local escaped_root = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    
    -- Пытаемся найти корень в начале пути
    local s, e = p:find("^" .. escaped_root)
    if s then
        -- Отрезаем корень и возможный слеш в начале
        p = p:sub(e + 1):gsub("^/", "")
    end
    
    return p
end

function M.read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    print(">>> [DISK WRITE] " .. path)
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

function M.get_file_outline(path)
    -- (Оставляем как было в прошлом ответе)
    local content, err = M.read_file(path)
    if not content then return "Error: " .. tostring(err) end
    
    local outline = {}
    local line_num = 0
    for line in content:gmatch("[^\r\n]+") do
        line_num = line_num + 1
        local clean = M.trim(line)
        if clean:match("^function") or clean:match("^class") or clean:match("^def") or clean:match("^export") or clean:match("M%..-%s=") then
            table.insert(outline, string.format("%03d: %s", line_num, clean))
        end
    end
    if #outline == 0 then return "(No definitions)" end
    if #outline > 50 then
        local t = {}
        for i=1,50 do table.insert(t, outline[i]) end
        return table.concat(t, "\n") .. "\n...[Truncated]"
    end
    return table.concat(outline, "\n")
end

function M.list_files_recursive(root_path)
    -- (Оставляем как было)
    local cmd = string.format("find '%s' -type f -not -path '*/.*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' 2>/dev/null", root_path)
    local p = io.popen(cmd)
    if not p then return "Error" end
    local out = p:read("*a")
    p:close()
    
    local files = {}
    local count = 0
    for line in out:gmatch("[^\r\n]+") do
        -- Убираем root из вывода find, чтобы список был красивым и относительным
        local rel = M.resolve_relative_path(root_path, line)
        if rel ~= "" then
            count = count + 1
            if count <= 300 then table.insert(files, rel) end
        end
    end
    return table.concat(files, "\n")
end

return M
