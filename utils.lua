local M = {}
local io = require("io")

local CHUNK_SIZE = 65536
local MAX_FILE_SIZE = 8192 * 8192

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
            local lines_count = M.count_lines_fast(full_path)
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
    local max_files = 200
    local count = 0

    for line in out:gmatch("[^\r\n]+") do
        if count >= max_files then break end

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
            count = count + 1
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

function M.escape_json_string(str)
    if type(str) ~= "string" then return tostring(str) end
    str = str:gsub("\\", "\\\\")
    str = str:gsub('"', '\\"')
    str = str:gsub("\n", "\\n")
    str = str:gsub("\r", "\\r")
    str = str:gsub("\t", "\\t")
    str = str:gsub("\b", "\\b")
    str = str:gsub("\f", "\\f")
    -- Escape remaining control characters 0x00-0x1F
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
    -- Strip null bytes
    str = str:gsub("\0", "")
    -- Replace invalid UTF-8 bytes with '?'
    local out = {}
    local i = 1
    while i <= #str do
        local byte = string.byte(str, i)
        if byte <= 0x7F then
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

-- Simple hash function for image deduplication (byte-based checksum, Lua 5.1 compatible)
local function _compute_image_hash(data)
    if not data or #data == 0 then return "" end
    local sum = 0
    local len = #data
    -- Sample bytes for speed on large images (every 64th byte + first 256 bytes)
    local step = 64
    for i = 1, len do
        if i <= 256 or i % step == 0 then
            sum = (sum + string.byte(data, i)) % 4294967295
        end
    end
    return string.format("%08x_%d", sum, len)
end

function M.estimate_image_tokens(img_table, tokens_per_byte)
    if not img_table or not img_table.base64_data then return 0 end
    tokens_per_byte = tokens_per_byte or 0.004
    return math.ceil(#img_table.base64_data * tokens_per_byte)
end

function M.get_image_dimensions(path)
    -- Try ffprobe first (ffmpeg suite)
    local safe_path = M.shell_quote(path)
    local cmd = string.format("ffprobe -v quiet -print_format json -show_entries stream=width,height %s 2>/dev/null", safe_path)
    local p = io.popen(cmd)
    if p then
        local out = p:read("*a")
        p:close()
        if out and out:match('"width"') and out:match('"height"') then
            local w = tonumber(out:match('"width"%s*:%s*(%d+)'))
            local h = tonumber(out:match('"height"%s*:%s*(%d+)'))
            if w and h then return w, h end
        end
    end

    -- Fallback: ImageMagick identify
    cmd = string.format("identify -format '%%w %%h' %s 2>/dev/null", safe_path)
    p = io.popen(cmd)
    if p then
        local out = p:read("*a")
        p:close()
        if out then
            local w, h = out:match("(%d+)%s+(%d+)")
            if w and h then return tonumber(w), tonumber(h) end
        end
    end

    return nil, nil
end

-- Compression statistics tracking
M._compress_stats = { total = 0, compressed = 0, skipped = 0, failed = 0 }

function M.compress_image(path, max_dim, quality)
    max_dim = max_dim or 512
    quality = quality or 60
    M._compress_stats.total = M._compress_stats.total + 1

    local w, h = M.get_image_dimensions(path)
    if not w or not h then return false, "Could not determine dimensions" end

    -- Already small enough
    if w <= max_dim and h <= max_dim then
        M._compress_stats.skipped = M._compress_stats.skipped + 1
        return true, "Already within bounds"
    end

    local safe_path = M.shell_quote(path)
    local tmp_path = path .. ".compress_tmp"

    -- Helper: detect MIME type from magic bytes after compression
    local function detect_mime_from_magic(fpath)
        local f = io.open(fpath, "rb")
        if not f then return nil end
        local header = f:read(4)
        f:close()
        if not header or #header < 3 then return nil end
        local b1, b2, b3 = string.byte(header, 1), string.byte(header, 2), string.byte(header, 3)
        local b4 = #header >= 4 and string.byte(header, 4) or 0
        -- JPEG: FF D8 FF
        if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then return "image/jpeg" end
        -- PNG: 89 50 4E 47
        if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return "image/png" end
        -- GIF: 47 49 46 38
        if b1 == 0x47 and b2 == 0x49 and b3 == 0x46 and b4 == 0x38 then return "image/gif" end
        -- WebP: RIFF .... WEBP  (first 4 bytes: 52 49 46 46)
        if b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46 then return "image/webp" end
        return nil
    end

    -- Helper: replace original with compressed, detect mime, return success
    local function finalize_compression(method_name)
        os.execute(string.format("mv %s %s", M.shell_quote(tmp_path), safe_path))
        M._compress_stats.compressed = M._compress_stats.compressed + 1
        -- Detect actual format after compression
        local detected_mime = detect_mime_from_magic(path)
        if detected_mime then
            return true, string.format("Compressed via %s (detected: %s)", method_name, detected_mime)
        end
        return true, string.format("Compressed via %s", method_name)
    end

    -- Try ffmpeg first (with 10s timeout)
    local cmd = string.format(
        "timeout 10s ffmpeg -i %s -vf \"scale=%d:%d:force_original_aspect_ratio=downscale\" -q:v %d -y %s 2>/dev/null",
        safe_path, max_dim, max_dim, math.ceil(31 * (100 - quality) / 100), tmp_path
    )
    local ok = os.execute(cmd)

    if ok == 0 then
        return finalize_compression("ffmpeg")
    elseif ok == 124 then
        -- timeout exit code
        os.execute(string.format("rm -f %s", M.shell_quote(tmp_path)))
        M._compress_stats.failed = M._compress_stats.failed + 1
        return false, "Compression timed out (ffmpeg)"
    end

    -- Fallback: ImageMagick convert (with 10s timeout)
    cmd = string.format(
        "timeout 10s convert %s -resize %dx%d -quality %d %s 2>/dev/null",
        safe_path, max_dim, max_dim, quality, tmp_path
    )
    ok = os.execute(cmd)

    if ok == 0 then
        return finalize_compression("ImageMagick")
    elseif ok == 124 then
        -- timeout exit code
        os.execute(string.format("rm -f %s", M.shell_quote(tmp_path)))
        M._compress_stats.failed = M._compress_stats.failed + 1
        return false, "Compression timed out (ImageMagick)"
    end

    -- Cleanup temp file on failure
    os.execute(string.format("rm -f %s", M.shell_quote(tmp_path)))
    M._compress_stats.failed = M._compress_stats.failed + 1
    return false, "Both ffmpeg and ImageMagick failed"
end

function M.load_images_from_dir(dir_path)
    if not dir_path then return {} end

    local safe_dir = M.shell_quote(dir_path)
    if os.execute(string.format("test -d %s", safe_dir)) ~= 0 then return {} end

    local exts = {"png", "jpg", "jpeg", "gif", "webp", "bmp"}
    local patterns = {}
    for _, ext in ipairs(exts) do
        table.insert(patterns, "-iname '*." .. ext .. "'")
    end
    local find_cmd = string.format("find %s -maxdepth 1 -type f \\( %s \\) 2>/dev/null", safe_dir, table.concat(patterns, " -o "))

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
            -- Compress image BEFORE reading (overwrites original on disk)
            M.compress_image(line, 512, 60)

            local f = io.open(line, "rb")
            if f then
                local header = f:read(3)
                local data = header and (header .. f:read("*a")) or nil
                f:close()

                -- Detect JPEG magic bytes (FF D8 FF) and override mime_type if needed
                if header and #header >= 3 then
                    local b1, b2, b3 = string.byte(header, 1), string.byte(header, 2), string.byte(header, 3)
                    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
                        mime = "image/jpeg"
                    end
                end

                if data and #data > 0 then
                    local hash = _compute_image_hash(data)
                    table.insert(images, {
                        path = line,
                        mime_type = mime,
                        base64_data = M.base64_encode(data),
                        hash = hash
                    })
                end
            end
        end
    end

    return images
end

return M