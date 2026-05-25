local M = {}
local io = require("io")

local CHUNK_SIZE = 65536
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

function M.deep_merge(base, specific)
    local res = {}
    if type(base) == "table" then
        for k, v in pairs(base) do res[k] = type(v) == "table" and M.deep_merge({}, v) or v end
    end
    if type(specific) == "table" then
        for k, v in pairs(specific) do res[k] = type(v) == "table" and M.deep_merge(res[k] or {}, v) or v end
    end
    return res
end

function M.load_config(filepath)
    local chunk, err = loadfile(filepath)
    if not chunk then return nil, err end
    
    local ok, res = pcall(chunk)
    if not ok then return nil, "Execution error: " .. tostring(res) end
    
    if type(res) == "table" then
        -- Поддержка легаси/корневого формата с M.get()
        if type(res.get) == "function" then
            return res.get()
        end
        return res
    end
    
    return nil, "Config must return a table"
end

function M.copy_file(src, dest)
    local input, err = io.open(src, "rb")
    if not input then return false, "Src open failed: " .. tostring(err) end

    local output, err_out = io.open(dest, "wb")
    if not output then
        input:close()
        return false, "Dest open failed: " .. tostring(err_out)
    end

    while true do
        local chunk = input:read(CHUNK_SIZE)
        if not chunk then break end
        output:write(chunk)
    end

    input:close()
    output:close()
    return true
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

function M.count_lines_fast(filepath)
    local f = io.open(filepath, "rb")
    if not f then return "?" end

    local count = 0
    local has_content = false

    while true do
        local chunk = f:read(CHUNK_SIZE)
        if not chunk then break end
        has_content = true
        local _, newlines = chunk:gsub("\n", "")
        count = count + newlines
    end
    f:close()

    if count == 0 and has_content then return 1 end
    return count
end

function M.list_files_recursive(root_path)
    local safe_root = M.shell_quote(root_path)
    local cmd = string.format("rg --files --hidden --glob '!.git/' --glob '!.e-va-conf/' --glob '!lua_modules/' --glob '!.luacov*' --glob '!*.report.out' --glob '!*.stats.out' --color never %s 2>/dev/null", safe_root)

    local p = io.popen(cmd)
    if not p then return "Error listing files" end
    local out = p:read("*a")
    p:close()

    local files = {}
    for line in out:gmatch("[^\r\n]+") do
        local rel = M.normalize_path(root_path, line)
        if rel ~= "" then
            local full_path = root_path .. "/" .. rel
            local lines_count = count_lines_fast(full_path)
            table.insert(files, string.format("%s (%s lines)", rel, tostring(lines_count)))
        end
    end

    if #files == 0 then return "(No files found)" end
    table.sort(files)
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

function M.restore_backup(full_path)
    local bak_path = full_path .. ".bak"
    local f = io.open(bak_path, "r")
    if not f then return false, "Backup not found" end
    f:close()

    return M.copy_file(bak_path, full_path)
end

function M.cleanup_backups(root_path)
    local safe_root = M.shell_quote(root_path)
    local cmd = string.format("find %s -type f -name '*.bak' -delete 2>&1", safe_root)
    local ok = os.execute(cmd)
    return ok == 0
end

function M.replace_lines(full_path, start_line, end_line, new_code)
    local content, err = M.read_file_range(full_path)
    if not content then return false, err end

    local lines = M.read_lines_raw(content)
    start_line = tonumber(start_line)
    end_line = tonumber(end_line)

    if start_line < 1 or end_line < start_line or start_line > #lines then
        return false, string.format("Invalid line range: %d-%d (File has %d lines)", start_line, end_line, #lines)
    end

    local new_lines = {}
    if new_code and new_code ~= "" then
        for line in new_code:gmatch("([^\n]*)\n?") do
            if line ~= "" or new_code:sub(-1) == "\n" then
                table.insert(new_lines, line)
            end
        end
        if #new_lines > 0 and new_lines[#new_lines] == "" and new_code:sub(-1) ~= "\n" then
            table.remove(new_lines)
        end
    end

    local count_to_remove = math.min(end_line, #lines) - start_line + 1
    for _ = 1, count_to_remove do
        table.remove(lines, start_line)
    end

    for i = #new_lines, 1, -1 do
        table.insert(lines, start_line, new_lines[i])
    end

    local final_content = table.concat(lines, "\n")
    return M.write_file(full_path, final_content)
end

function M.explore_directory(root_path, target_subpath, max_depth)
    local target = target_subpath and target_subpath ~= "" and target_subpath or "."
    local full_target = M.normalize_path(root_path, target)

    local absolute_target = root_path .. "/" .. full_target
    local safe_target = M.shell_quote(absolute_target)
    local depth = tonumber(max_depth) or 1

    local cmd = string.format(
        "find %s -maxdepth %d -not -path '*/\\.git*' -not -path '*/node_modules*' -not -path '*/build*' -not -path '*/\\.e-va-conf*' -not -path '*/lua_modules*' -not -path '*/.luacov*' -not -path '*/*.report.out' -not -path '*/*.stats.out' 2>/dev/null | sort",
        safe_target, depth
    )

    local p = io.popen(cmd)
    if not p then return "[ERROR] Failed to execute directory scan" end
    local out = p:read("*a")
    p:close()

    local files = {}
    for line in out:gmatch("[^\r\n]+") do
        local rel = M.normalize_path(root_path, line)
        if rel ~= "" and rel ~= full_target then
            local full_path = root_path .. "/" .. rel
            local safe_full_path = M.shell_quote(full_path)
            local is_dir = os.execute(string.format("test -d %s", safe_full_path)) == 0

            if is_dir then
                table.insert(files, "  " .. rel .. "/")
            else
                local lines_count = M.count_lines_fast(full_path)
                table.insert(files, string.format("  %s (%s lines)", rel, tostring(lines_count)))
            end
        end
    end

    if #files == 0 then return "(Directory is empty or access denied)" end
    return string.format("Directory: /%s\n%s", full_target, table.concat(files, "\n"))
end

function M.apply_agent_defaults(config)
    if not config or not config.AGENTS then return config end
    local defaults = config.AGENT_DEFAULTS
    if not defaults then return config end

    local function apply_one(agent)
        if type(agent) ~= "table" then return end

        if agent.url == nil and defaults.url ~= nil then agent.url = defaults.url end
        if agent.model == nil and defaults.model ~= nil then agent.model = defaults.model end
        if agent.is_reasoning == nil and defaults.is_reasoning ~= nil then agent.is_reasoning = defaults.is_reasoning end
        if agent.prompt_file == nil and defaults.prompt_file ~= nil then agent.prompt_file = defaults.prompt_file end
        if agent.allowed_tools == nil and defaults.allowed_tools ~= nil then agent.allowed_tools = defaults.allowed_tools end

        if defaults.params then
            agent.params = M.deep_merge(defaults.params, agent.params or {})
        end
    end

    for _, agent in pairs(config.AGENTS) do
        apply_one(agent)
    end
    return config
end

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

function M.load_images_from_dir(dir_path)
    if not dir_path then return {} end

    local safe_dir = M.shell_quote(dir_path)
    local exists = os.execute(string.format("test -d %s", safe_dir))
    if not exists then return {} end

    local exts = {"png", "jpg", "jpeg", "gif", "webp", "bmp"}
    local patterns = {}
    for _, ext in ipairs(exts) do
        table.insert(patterns, "-iname '*." .. ext .. "'")
    end
    local find_cmd = string.format("find %s -maxdepth 1 -type f %s 2>/dev/null", safe_dir, table.concat(patterns, " -o "))

    local p = io.popen(find_cmd)
    if not p then return {} end
    local output = p:read("*a")
    p:close()

    local mime_map = {
        ["png"] = "image/png",
        ["jpg"] = "image/jpeg",
        ["jpeg"] = "image/jpeg",
        ["gif"] = "image/gif",
        ["webp"] = "image/webp",
        ["bmp"] = "image/bmp"
    }

    local images = {}
    for line in output:gmatch("[^\r\n]+") do
        if line == "" then break end
        local fname = line:match("^.*/(.+)$") or line
        local ext = fname:match("%.([^%.]+)$"):lower()
        local mime = mime_map[ext]
        if mime then
            local f = io.open(line, "rb")
            if f then
                local data = f:read("*a")
                f:close()
                if data and #data > 0 then
                    table.insert(images, {
                        path = line,
                        mime_type = mime,
                        base64_data = M.base64_encode(data)
                    })
                end
            end
        end
    end

    return images
end

return M