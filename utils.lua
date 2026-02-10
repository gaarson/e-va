local M = {}
local io = require("io")

function M.trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function M.resolve_relative_path(root, raw_path)
    local p = M.trim(raw_path)
    p = p:gsub("^%./", "")
    local escaped_root = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    if p:find("^" .. escaped_root) then
        p = p:sub(#root + 2)
    end
    return p:gsub("^/", "")
end

function M.read_file_range(raw_path_arg)
    local path = raw_path_arg
    local start_line, end_line

    local p, s, e = raw_path_arg:match("^(.-):%D*(%d+)%D+(%d+)%D*$")
    if p then
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
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    local ok, w_err = f:write(content)
    f:close()
    return ok, w_err
end

function M.list_files_recursive(root_path)
    local cmd = string.format("rg --files --hidden --glob '!.git/' --color never '%s' 2>/dev/null", root_path)
    local p = io.popen(cmd)
    if not p then return "Error listing files" end
    local out = p:read("*a")
    p:close()

    local files = {}
    local count = 0
    for line in out:gmatch("[^\r\n]+") do
        local rel = M.resolve_relative_path(root_path, line)
        if rel ~= "" then
            count = count + 1
            if count <= 600 then table.insert(files, rel) end
        end
    end
    if count == 0 then return "(No files found)" end
    return table.concat(files, "\n")
end

function M.grep_files(root_path, query)
    local safe_query = query:gsub("'", "'\\''")
    local cmd = string.format("rg -n --no-heading --hidden --glob '!.git/' --color never '%s' '%s' | head -n 30", safe_query, root_path)
    local p = io.popen(cmd)
    if not p then return "Error running rg" end
    local out = p:read("*a")
    p:close()
    
    if #out == 0 then return "(No matches found)" end
    return out
end

return M
