local M = {}
local io = require("io")

function M.resolve_relative_path(root, raw_path)
    local p = M.trim(raw_path)
    p = p:gsub("^%./", "")
    local escaped_root = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    local s, e = p:find("^" .. escaped_root)
    if s then
        p = p:sub(e + 1):gsub("^/", "")
    end
    return p
end

function M.read_file_range(raw_path_arg)
    -- === FIX: Robust parsing ===
    -- Модель может написать: "file.lua:10-20", "file.lua:line 10 to 20", "file.lua:start_line-10..."
    -- Ищем разделитель двоеточие, за которым следуют цифры
    
    local path = raw_path_arg
    local start_line = nil
    local end_line = nil

    -- Пытаемся найти паттерн "путь:цифры...цифры"
    -- %D* означает "любое количество НЕ цифр"
    local p, s, e = raw_path_arg:match("^(.-):%D*(%d+)%D+(%d+)%D*$")
    
    if p and s and e then
        path = p
        start_line = tonumber(s)
        end_line = tonumber(e)
    end

    local f, err = io.open(path, "r")
    if not f then return nil, err end

    local content = {}
    local line_num = 0
    
    if start_line and end_line then
        for line in f:lines() do
            line_num = line_num + 1
            if line_num >= start_line and line_num <= end_line then
                table.insert(content, string.format("%04d | %s", line_num, line))
            end
            if line_num > end_line then break end
        end
        f:close()
        if #content == 0 then
            return "(Empty range or End of File reached)"
        end
        return table.concat(content, "\n")
    else
        f:close()
        local fb, err2 = io.open(path, "rb")
        if not fb then return nil, err2 end
        local all = fb:read("*a")
        fb:close()
        return all
    end
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
    local content, err = M.read_file_range(path)
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
    local cmd = string.format("find '%s' -type f -not -path '*/.*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' 2>/dev/null", root_path)
    local p = io.popen(cmd)
    if not p then return "Error" end
    local out = p:read("*a")
    p:close()

    local files = {}
    local count = 0
    for line in out:gmatch("[^\r\n]+") do
        local rel = M.resolve_relative_path(root_path, line)
        if rel ~= "" then
            count = count + 1
            if count <= 700 then table.insert(files, rel) end
        end
    end
    return table.concat(files, "\n")
end

return M
