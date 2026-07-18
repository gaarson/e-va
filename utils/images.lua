
local io = require("io")

local encoding = require("utils.encoding")

local directory = require("utils.directory")
local strings = require("utils.strings")


local M = {}


-- Compression statistics tracking

M._compress_stats = { total = 0, compressed = 0, skipped = 0, failed = 0 }


-- Simple hash function for image deduplication

local function _compute_image_hash(data)

    if not data or #data == 0 then return "" end

    local sum = 0

    local len = #data

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

    if w <= max_dim and h <= max_dim then

        M._compress_stats.skipped = M._compress_stats.skipped + 1

        return true, "Already within bounds"

    end

    local safe_path = strings.shell_quote(path)

    local tmp_path = path .. ".compress_tmp"

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

    local cmd = string.format(

        "timeout 10s ffmpeg -i %s -vf \"scale=%d:%d:force_original_aspect_ratio=downscale\" -q:v %d -y %s 2>/dev/null",

        safe_path, max_dim, max_dim, math.ceil(31 * (100 - quality) / 100), tmp_path

    )

    local ok = os.execute(cmd)

    if ok == 0 then

        return finalize_compression("ffmpeg")

    elseif ok == 124 then

        os.execute(string.format("rm -f %s", strings.shell_quote(tmp_path)))

        M._compress_stats.failed = M._compress_stats.failed + 1

        return false, "Compression timed out (ffmpeg)"

    end

    cmd = string.format(

        "timeout 10s convert %s -resize %dx%d -quality %d %s 2>/dev/null",

        safe_path, max_dim, max_dim, quality, tmp_path

    )

    ok = os.execute(cmd)

    if ok == 0 then

        return finalize_compression("ImageMagick")

    elseif ok == 124 then

        os.execute(string.format("rm -f %s", strings.shell_quote(tmp_path)))

        M._compress_stats.failed = M._compress_stats.failed + 1

        return false, "Compression timed out (ImageMagick)"

    end

    os.execute(string.format("rm -f %s", strings.shell_quote(tmp_path)))

    M._compress_stats.failed = M._compress_stats.failed + 1

    return false, "Both ffmpeg and ImageMagick failed"

end


function M.load_images_from_dir(dir_path)

    if not dir_path then return {} end

    local safe_dir = strings.shell_quote(dir_path)

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

        ["png"] = "image/png", ["jpg"] = "image/jpeg", ["jpeg"] = "image/jpeg",

        ["gif"] = "image/gif", ["webp"] = "image/webp", ["bmp"] = "image/bmp"

    }

    local images = {}

    for line in output:gmatch("[^\r\n]+") do

        if line == "" then break end

        local fname = line:match("^.*/(.+)$") or line

        local ext = fname:match("%.([^%.]+)$"):lower()

        local mime = mime_map[ext]

        if mime then

            M.compress_image(line, 512, 60)

            local f = io.open(line, "rb")

            if f then

                local header = f:read(3)

                local data = header and (header .. f:read("*a")) or nil

                f:close()

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

                        base64_data = encoding.base64_encode(data),

                        hash = hash

                    })

                end

            end

        end

    end

    return images

end


return M

