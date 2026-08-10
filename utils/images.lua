local io = require("io")
local encoding = require("utils.encoding")
local directory = require("utils.directory")
local strings = require("utils.strings")
local logger = require("logger")
local M = {}
-- Compression statistics tracking
M._compress_stats = { total = 0, compressed = 0, skipped = 0, failed = 0 }
-- Simple hash function for image deduplication (O(1) constant sampling)
-- Samples: first 256 bytes, last 128 bytes, and stride-256 positions
local function _compute_image_hash(data)
    if not data or #data == 0 then return "" end
    local sum = 0
    local len = #data
    -- Sample first 256 bytes
    local end_first = math.min(256, len)
    for i = 1, end_first do
        sum = (sum + string.byte(data, i)) % 4294967295
    end
    -- Sample last 128 bytes (avoid overlap with first 256)
    local start_last = math.max(257, len - 127)
    for i = start_last, len do
        sum = (sum + string.byte(data, i)) % 4294967295
    end
    -- Stride-256 sampling across the middle region
    for i = 257, len - 128, 256 do
        sum = (sum + string.byte(data, i)) % 4294967295
    end
    return string.format("%08x_%d", sum, len)
end
function M.estimate_image_tokens(img_table, tokens_per_byte)
    if not img_table or not img_table.base64_data then return 0 end
    tokens_per_byte = tokens_per_byte or 0.004
    return math.ceil(#img_table.base64_data * tokens_per_byte)
end
function M.get_image_dimensions(path)
    local safe_path = strings.shell_quote(path)
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
function M.compress_image(path, max_dim, quality)
    max_dim = max_dim or 512
    quality = quality or 60
    M._compress_stats.total = M._compress_stats.total + 1
    local w, h = M.get_image_dimensions(path)
    if not w or not h then return false, "Could not determine dimensions" end
    logger.info(string.format("[IMAGE COMPRESS] path=%s, dims=%dx%d, max_dim=%d", path, w, h, max_dim))
    -- Fast-path: skip compression for small files (< 200KB)
    local f_stat = io.open(path, "rb")
    if f_stat then
        local fsize = f_stat:seek("end")
        f_stat:close()
        if fsize < 200 * 1024 then
            M._compress_stats.skipped = M._compress_stats.skipped + 1
            return true, string.format("Small file (%.1f KB), skipped", fsize / 1024)
        end
    end
    if w <= max_dim and h <= max_dim then
        M._compress_stats.skipped = M._compress_stats.skipped + 1
        return true, "Already within bounds"
    end
    logger.info(string.format("[IMAGE COMPRESS] Compression needed for %s (%dx%d > %d)", path, w, h, max_dim))
    local safe_path = strings.shell_quote(path)
    local tmp_path = path .. ".compress_tmp"
    local bak_path = path .. ".compress_bak"
    -- Backup original before compression
    os.execute(string.format("cp %s %s", safe_path, strings.shell_quote(bak_path)))
    local function detect_mime_from_magic(fpath)
        local f = io.open(fpath, "rb")
        if not f then return nil end
        local header = f:read(4)
        f:close()
        if not header or #header < 3 then return nil end
        local b1, b2, b3 = string.byte(header, 1), string.byte(header, 2), string.byte(header, 3)
        local b4 = #header >= 4 and string.byte(header, 4) or 0
        if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then return "image/jpeg" end
        if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return "image/png" end
        if b1 == 0x47 and b2 == 0x49 and b3 == 0x46 and b4 == 0x38 then return "image/gif" end
        if b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46 then return "image/webp" end
        return nil
    end
    local function finalize_compression(method_name)
        os.execute(string.format("mv %s %s", strings.shell_quote(tmp_path), safe_path))
        M._compress_stats.compressed = M._compress_stats.compressed + 1
        local detected_mime = detect_mime_from_magic(path)
        if detected_mime then
            return true, string.format("Compressed via %s (detected: %s)", method_name, detected_mime)
        end
        return true, string.format("Compressed via %s", method_name)
    end
    -- Helper: run command and get reliable exit code via io.popen
    local function run_cmd_with_exit_code(cmd_str)
        local full_cmd = string.format("(%s); echo EXITCODE:$?", cmd_str)
        local p = io.popen(full_cmd .. " 2>/dev/null")
        if not p then return 99 end
        local output = p:read("*a")
        local rc = 99
        if output then
            local ec = output:match("EXITCODE:(%d+)")
            if ec then rc = tonumber(ec) end
        end
        p:close()
        return rc
    end
    local cmd = string.format(
        "timeout 5s ffmpeg -i %s -vf \"scale=%d:%d:force_original_aspect_ratio=downscale\" -t 2 -pix_fmt yuv420p -q:v %d -y %s",
        safe_path, max_dim, max_dim, math.ceil(31 * (100 - quality) / 100), tmp_path
    )
    local rc = run_cmd_with_exit_code(cmd)
    if rc == 0 then
        local ok, msg = finalize_compression("ffmpeg")
        os.execute(string.format("rm -f %s", strings.shell_quote(bak_path)))
        return ok, msg
    elseif rc == 124 then
        os.execute(string.format("rm -f %s", strings.shell_quote(tmp_path)))
        -- Restore backup on timeout
        os.execute(string.format("mv %s %s", strings.shell_quote(bak_path), safe_path))
        M._compress_stats.failed = M._compress_stats.failed + 1
        return false, "Compression timed out (ffmpeg)"
    end
    cmd = string.format(
        "timeout 5s convert %s -resize %dx%d -quality %d %s",
        safe_path, max_dim, max_dim, quality, tmp_path
    )
    rc = run_cmd_with_exit_code(cmd)
    if rc == 0 then
        local ok, msg = finalize_compression("ImageMagick")
        os.execute(string.format("rm -f %s", strings.shell_quote(bak_path)))
        return ok, msg
    elseif rc == 124 then
        os.execute(string.format("rm -f %s", strings.shell_quote(tmp_path)))
        -- Restore backup on timeout
        os.execute(string.format("mv %s %s", strings.shell_quote(bak_path), safe_path))
        M._compress_stats.failed = M._compress_stats.failed + 1
        return false, "Compression timed out (ImageMagick)"
    end
    -- Both failed: only restore backup if original file was modified
    os.execute(string.format("rm -f %s", strings.shell_quote(tmp_path)))
    local current_size = 0
    local current_f = io.open(path, "rb")
    if current_f then
        current_size = current_f:seek("end")
        current_f:close()
    end
    local bak_size = 0
    local bak_f = io.open(bak_path, "rb")
    if bak_f then
        bak_size = bak_f:seek("end")
        bak_f:close()
    end
    -- Only restore if the original file size differs from backup (meaning it was corrupted/modified)
    if current_size ~= bak_size then
        os.execute(string.format("mv %s %s", strings.shell_quote(bak_path), safe_path))
    else
        os.execute(string.format("rm -f %s", strings.shell_quote(bak_path)))
    end
    M._compress_stats.failed = M._compress_stats.failed + 1
    return false, "Both ffmpeg and ImageMagick failed"
end
function M.load_images_from_dir(dir_path)
    if not dir_path then return {} end
    logger.info(string.format("[IMAGE DIAG] load_images_from_dir called with dir_path=%s", dir_path))
    local safe_dir = strings.shell_quote(dir_path)
    local p = io.popen(string.format("test -d %s && echo OK", safe_dir) .. " 2>/dev/null")
    if not p then return {} end
    local result = p:read("*l")
    p:close()
    if result ~= "OK" then return {} end
    local exts = {"png", "jpg", "jpeg", "gif", "webp", "bmp"}
    local patterns = {}
    for _, ext in ipairs(exts) do
        table.insert(patterns, "-iname '*." .. ext .. "'")
    end
    local find_cmd = string.format("find %s -maxdepth 1 -type f \\( %s \\) 2>/dev/null", safe_dir, table.concat(patterns, " -o "))
    local p = io.popen(find_cmd)
    if not p then
        logger.warn(string.format("[IMAGE] find_cmd failed to open: %s", find_cmd))
        return {}
    end
    local output = p:read("*a")
    p:close()
    -- Diagnostic: log raw output line count
    local line_count = 0
    for _ in output:gmatch("[^\r\n]+") do line_count = line_count + 1 end
    logger.info(string.format("[IMAGE] find_cmd='%s' returned %d lines", find_cmd, line_count))
    local mime_map = {
        ["png"] = "image/png", ["jpg"] = "image/jpeg", ["jpeg"] = "image/jpeg",
        ["gif"] = "image/gif", ["webp"] = "image/webp", ["bmp"] = "image/bmp"
    }
    -- Detect MIME from magic bytes (used after compression to get correct type)
    local function detect_mime_from_header(header)
        if not header or #header < 4 then return nil end
        local b1, b2, b3, b4 = string.byte(header, 1), string.byte(header, 2), string.byte(header, 3), string.byte(header, 4)
        if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then return "image/jpeg" end
        if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return "image/png" end
        if b1 == 0x47 and b2 == 0x49 and b3 == 0x46 then return "image/gif" end
        if b1 == 0x52 and b2 == 0x49 and b3 == 0x46 and b4 == 0x46 then return "image/webp" end
        if b1 == 0x42 and b2 == 0x4D then return "image/bmp" end
        return nil
    end
    local images = {}
    for line in output:gmatch("[^\r\n]+") do
        if line == "" then break end
        local fname = line:match("^.*/(.+)$") or line
        local ext = fname:match("%.([^%.]+)$"):lower()
        local mime = mime_map[ext]
        if mime then
            local comp_ok, comp_msg = M.compress_image(line, 512, 60)
            if not comp_ok then
                logger.warn(string.format('[IMAGE COMPRESS FAILED] %s: %s', line, comp_msg))
            end
            local f = io.open(line, "rb")
            if f then
                local header = f:read(4)
                local data = header and (header .. f:read("*a")) or nil
                f:close()
                -- Re-detect MIME from magic bytes after compression (compression may change format)
                if header and #header >= 4 then
                    local detected = detect_mime_from_header(header)
                    if detected then
                        mime = detected
                    end
                end
                if data and #data > 0 then
                    local b64 = encoding.base64_encode(data)
                    local hash = _compute_image_hash(b64)
                    logger.info(string.format("[IMAGE] Loaded image: path=%s, mime=%s, b64_len=%d", line, mime, #b64))
                    table.insert(images, {
                        path = line,
                        mime_type = mime,
                        base64_data = b64,
                        hash = hash
                    })
                end
            end
        end
    end
    return images
end
return M