local M = {}
local io = require("io")

local MAX_FILE_SIZE = 1024 * 1024 

function M.trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function M.normalize_path(root, raw_path)
    if not raw_path then return "" end
    local p = M.trim(raw_path)
    
    p = p:gsub("^path%s*[:=]%s*", ""):gsub("^file%s*[:=]%s*", ""):gsub("['\"]", "")
    p = M.trim(p)
    p = p:gsub("^%./", "")

    local escaped_root = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    if p:find("^" .. escaped_root) then
        p = p:sub(#root + 2)
    end
    return p:gsub("^/", "")
end

function M.read_file_range(full_path)
    local f, err = io.open(full_path, "rb") 
    if not f then return nil, "IO Error: " .. tostring(err) end

    local size = f:seek("end")
    f:seek("set", 0)

    local content
    if size > MAX_FILE_SIZE then
        local head_size = 512 * 1024 
        local tail_size = 10 * 1024  
        
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
    local safe_root = M.shell_quote(root_path)
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
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

function M.read_file_numbered(path, start_line, end_line)
    local f, err = io.open(path, "r")
    if not f then return nil, "IO Error: " .. tostring(err) end

    local lines = {}
    local idx = 0
    start_line = start_line or 1
    end_line = end_line or 999999

    for line in f:lines() do
        idx = idx + 1
        if idx >= start_line and idx <= end_line then
            table.insert(lines, string.format("%4d | %s", idx, line))
        end
        if idx > end_line then break end
    end
    f:close()
    
    return table.concat(lines, "\n"), idx
end

function M.read_lines_raw(content)
    local lines = {}
    if not content then return lines end
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in content:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end
    if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
    return lines
end

function M.read_file_lines(path, start_line, end_line)
    local f, err = io.open(path, "r")
    if not f then return nil, "IO Error: " .. tostring(err) end

    local lines = {}
    local idx = 0
    for line in f:lines() do
        idx = idx + 1
        if idx >= start_line and idx <= end_line then
            table.insert(lines, string.format("%d| %s", idx, line))
        end
        if idx > end_line then break end
    end
    f:close()

    if #lines == 0 then
        return nil, "Range outside of file boundaries (File has " .. idx .. " lines)."
    end
    
    return table.concat(lines, "\n"), idx 
end

return M
