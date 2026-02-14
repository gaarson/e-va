local M = {}
local io = require("io")

-- Hard limit: 1MB. В Lua 5.1/JIT строки интернируются, память дорогая.
local MAX_FILE_SIZE = 1024 * 1024 

function M.trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function M.normalize_path(root, raw_path)
    if not raw_path then return "" end
    local p = M.trim(raw_path)
    -- Удаляем артефакты, которые может выдать LLM
    p = p:gsub("^path=", ""):gsub("^file=", ""):gsub("['\"]", "")
    p = M.trim(p)
    p = p:gsub("^%./", "")

    -- Экранируем спецсимволы для pattern matching
    local escaped_root = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    if p:find("^" .. escaped_root) then
        p = p:sub(#root + 2)
    end
    -- Убираем ведущий слеш, чтобы путь был относительным
    return p:gsub("^/", "")
end

function M.read_file_range(full_path)
    local f, err = io.open(full_path, "rb") -- "rb" важно для бинарной безопасности
    if not f then return nil, "IO Error: " .. tostring(err) end

    -- Syscall: lseek (узнаем размер без чтения)
    local size = f:seek("end")
    f:seek("set", 0)

    local content
    if size > MAX_FILE_SIZE then
        -- Partial Read: читаем голову и хвост, чтобы не забить RAM
        local head_size = 512 * 1024 -- 512KB
        local tail_size = 10 * 1024  -- 10KB
        
        local head = f:read(head_size)
        f:seek("end", -tail_size)
        local tail = f:read(tail_size)
        
        content = head .. "\n\n...[SNIPPED " .. (size - head_size - tail_size) .. " BYTES]...\n\n" .. tail
    else
        content = f:read("*a")
    end
    
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
    -- Используем shell_quote для защиты root_path
    local safe_root = M.shell_quote(root_path)
    -- Добавляем -L, чтобы следовать по симлинкам (опционально, но полезно)
    local cmd = string.format("rg --files --hidden --glob '!.git/' --color never %s 2>/dev/null", safe_root)
    
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

function M.shell_quote(str)
    if not str or str == "" then return "''" end
    -- Замена одиночной кавычки на sequence '\'' для bash/sh
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

return M
