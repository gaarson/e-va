local M = {}
local io = require("io")

function M.trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Критически важно: превращает "path='src/main.js'" в "src/main.js"
function M.normalize_path(root, raw_path)
    if not raw_path then return "" end
    -- Убираем префиксы path=, file=, кавычки и пробелы
    local p = M.trim(raw_path)
    p = p:gsub("^path=", ""):gsub("^file=", ""):gsub("['\"]", "")
    p = M.trim(p)
    
    -- Убираем ./ в начале
    p = p:gsub("^%./", "")
    
    -- Разрешаем относительные пути
    local escaped_root = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    if p:find("^" .. escaped_root) then
        p = p:sub(#root + 2)
    end
    return p:gsub("^/", "")
end

function M.read_file_range(full_path)
    local f, err = io.open(full_path, "r")
    if not f then return nil, "IO Error: " .. tostring(err) end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    local ok, w_err = f:write(content)
    f:close()
    return ok, w_err
end

function M.list_files_recursive(root_path)
    -- Используем rg для скорости и игнорирования мусора (.git, node_modules)
    local cmd = string.format("rg --files --hidden --glob '!.git/' --color never '%s' 2>/dev/null | head -n 600", root_path)
    local p = io.popen(cmd)
    if not p then return "Error listing files" end
    local out = p:read("*a")
    p:close()
    
    local files = {}
    for line in out:gmatch("[^\r\n]+") do
        local rel = M.normalize_path(root_path, line)
        if rel ~= "" then table.insert(files, rel) end
    end
    if #files == 0 then return "(No files found)" end
    return table.concat(files, "\n")
end

return M
