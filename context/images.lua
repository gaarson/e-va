-- context/images.lua

-- Image management extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.

local M = {}

local utils = require("utils")
local logger = require("logger")


-- ============================================================================
-- LOAD IMAGES FROM DIRECTORY
-- ============================================================================

function M.load_images(ctx, dir_path)
    if not dir_path or dir_path == "" then
        ctx.images = {}
        ctx.images_loaded = false
        return
    end
    local socket = require("socket")
    local t_load = socket.gettime()
    local raw_images = utils.load_images_from_dir(dir_path)
    logger.info(string.format("[IMAGE DIAG] Loaded %d raw images from dir", #raw_images))
    local total_raw = 0
    for _, img in ipairs(raw_images) do total_raw = total_raw + #(img.base64_data or "") end
    logger.info(string.format("[IMAGE DIAG] Total raw base64 size: %d bytes (%.1f KB)", total_raw, total_raw / 1024))
    local max_bytes = (ctx.config.IMAGE_CONFIG and ctx.config.IMAGE_CONFIG.max_images_base64_bytes) or (4 * 1024 * 1024)
    local max_age_hours = (ctx.config.IMAGE_CONFIG and ctx.config.IMAGE_CONFIG.max_image_age_hours) or 24

    -- Filter by age: skip images older than max_age_hours
    local now = os.time()
    local age_seconds = max_age_hours * 3600
    local aged_filtered = {}
    for _, img in ipairs(raw_images) do
        local safe_path = utils.shell_quote(img.path)
        local mod_time = 0
        -- Try stat to get modification time (cross-platform)
        local cmd = string.format("stat -c %%Y %s 2>/dev/null || stat -f %%m %s 2>/dev/null", safe_path, safe_path)
        local p = io.popen(cmd)
        if p then
            local t = p:read("*l")
            p:close()
            if t then mod_time = tonumber(t) or 0 end
        end
        if mod_time > 0 and (now - mod_time) > age_seconds then
            logger.info(string.format("[IMAGE] Skipping old image %s (age: %.1f hours)", img.path, (now - mod_time) / 3600))
        else
            table.insert(aged_filtered, img)
            -- Attach mod_time for sorting
            img.mod_time = mod_time
        end
    end

    -- Sort by modification time descending (newest first)
    table.sort(aged_filtered, function(a, b)
        local ta = a.mod_time or 0
        local tb = b.mod_time or 0
        return ta > tb
    end)

    local total_b64 = 0
    local filtered = {}
    for _, img in ipairs(aged_filtered) do
        local sz = #(img.base64_data or "")
        if total_b64 + sz <= max_bytes then
            table.insert(filtered, img)
            total_b64 = total_b64 + sz
        else
            logger.info(string.format("[IMAGE] Skipping image %s (%d bytes) — exceeds base64 budget %d", img.path, sz, max_bytes))
        end
    end

    logger.info(string.format("[IMAGE DIAG] Budget filter: %d images passed, total b64 size: %d bytes (%.1f KB)", #filtered, total_b64, total_b64 / 1024))
    ctx.images = filtered
    ctx.images_loaded = (#ctx.images > 0)
    local elapsed = socket.gettime() - t_load
    logger.info(string.format("[IMAGE DIAG] load_images completed: %d images, %.3fs elapsed", #filtered, elapsed))
    -- Trim to capacity after loading
    M.trim_images(ctx)
end


-- ============================================================================
-- TRIM IMAGES (LRU-style: remove oldest / already-sent images when over capacity)
-- ============================================================================
function M.trim_images(ctx, max_count, max_total_bytes)
    max_count = max_count or ((ctx.config.IMAGE_CONFIG and ctx.config.IMAGE_CONFIG.max_images_per_turn) or 10)
    max_total_bytes = max_total_bytes or ((ctx.config.IMAGE_CONFIG and ctx.config.IMAGE_CONFIG.max_images_base64_bytes) or (4 * 1024 * 1024))
    -- Phase 1: Drop already-sent images if we have more than 2x the cap
    local double_cap = max_count * 2
    if #ctx.images > double_cap and ctx.last_sent_image_hashes and next(ctx.last_sent_image_hashes) then
        local trimmed = {}
        for _, img in ipairs(ctx.images) do
            local h = img.hash or ""
            if h ~= "" and ctx.last_sent_image_hashes[h] then
                -- Already sent, safe to drop
            else
                table.insert(trimmed, img)
            end
        end
        if #trimmed < #ctx.images then
            logger.info(string.format("[IMAGE] Dropped %d already-sent images (was %d, now %d)", #ctx.images - #trimmed, #ctx.images, #trimmed))
            ctx.images = trimmed
        end
    end
    -- Phase 2: Trim oldest images (first in array = oldest) to fit count budget
    while #ctx.images > max_count do
        local removed = table.remove(ctx.images, 1)  -- remove oldest (head)
        logger.info(string.format("[IMAGE] trim_images: removed oldest image (hash=%s) to fit count cap %d", removed.hash or "nil", max_count))
    end
    -- Phase 3: Trim oldest images to fit byte budget
    local total_b64 = 0
    for _, img in ipairs(ctx.images) do total_b64 = total_b64 + #(img.base64_data or "") end
    while total_b64 > max_total_bytes and #ctx.images > 0 do
        local removed = table.remove(ctx.images, 1)  -- remove oldest
        total_b64 = total_b64 - #(removed.base64_data or "")
        logger.info(string.format("[IMAGE] trim_images: removed oldest image (hash=%s, %d bytes) to fit byte budget %d", removed.hash or "nil", #(removed.base64_data or ""), max_total_bytes))
    end
    ctx.images_loaded = (#ctx.images > 0)
end
-- ============================================================================
-- ADD IMAGE
-- ============================================================================
function M.add_image(ctx, base64_data, mime_type)
    if not base64_data or base64_data == "" then return end
    mime_type = mime_type or "image/png"
    local max_imgs = (ctx.config.IMAGE_CONFIG and ctx.config.IMAGE_CONFIG.max_images_per_turn) or 10
    if #ctx.images >= max_imgs then
        logger.warn(string.format("[IMAGE] Image cap reached (%d). Rejecting new image.", max_imgs))
        return
    end
    -- Compute inline hash for deduplication (sampled: first 256 bytes + every 64th byte)
    local socket = require("socket")
    local t_hash = socket.gettime()
    local sum = 0
    local len = #base64_data
    local step = 64
    for i = 1, len do
        if i <= 256 or i % step == 0 then
            sum = (sum + string.byte(base64_data, i)) % 4294967295
        end
    end
    local hash = string.format("%08x_%d", sum, len)
    local hash_elapsed = socket.gettime() - t_hash
    logger.info(string.format("[IMAGE DIAG] add_image hash: b64_len=%d, hash=%s, time=%.4fs", len, hash, hash_elapsed))
    table.insert(ctx.images, { base64_data = base64_data, mime_type = mime_type, hash = hash })
    ctx.images_loaded = true
end


-- ============================================================================

-- PURGE IMAGES

-- ============================================================================

function M.purge_images(ctx)
    ctx.images = {}
    ctx.images_loaded = false
    ctx.last_sent_image_hashes = {}
end


-- ============================================================================

-- GET IMAGE CONTENT PARTS

-- ============================================================================

function M.get_image_content_parts(ctx)
    if not ctx.images or #ctx.images == 0 then return {} end
    local parts = {}
    for _, img in ipairs(ctx.images) do
        table.insert(parts, { type = "image_url", image_url = { url = "data:" .. img.mime_type .. ";base64," .. img.base64_data } })
    end
    return parts
end


-- ============================================================================

-- INJECT IMAGES INTO MESSAGES (called from builder.build_context)

-- Returns: (injected_messages, total_image_tokens)

-- ============================================================================

function M.inject_images_into_messages(ctx, messages, tokens_per_byte)
    if not ctx.images_loaded or #ctx.images == 0 then
        return messages, 0
    end

    -- Filter out images already sent (dedup by hash)
    local new_images = {}
    for _, img in ipairs(ctx.images) do
        local h = img.hash or ""
        if h == "" or not ctx.last_sent_image_hashes[h] then
            table.insert(new_images, img)
        end
    end

    if #new_images == 0 then
        return messages, 0
    end
    local socket = require("socket")
    local t_inject = socket.gettime()
    -- Log injection details
    local total_inject_b64 = 0
    for _, img in ipairs(new_images) do total_inject_b64 = total_inject_b64 + #(img.base64_data or "") end
    logger.info(string.format("[IMAGE DIAG] Injecting %d new images, total b64 size: %d bytes (%.1f KB)", #new_images, total_inject_b64, total_inject_b64 / 1024))
    local formatted_images = {}
    for _, img in ipairs(new_images) do
        table.insert(formatted_images, {
            type = "image_url",
            image_url = {
                url = "data:" .. img.mime_type .. ";base64," .. img.base64_data
            }
        })
    end

    local injected = false
    for i = #messages, 1, -1 do
        if messages[i].role == "user" then
            local content = messages[i].content
            if type(content) == "table" then
                -- Already a multi-part array: append image parts
                for _, img_part in ipairs(formatted_images) do
                    table.insert(content, img_part)
                end
            else
                -- String content: wrap into multi-part array with text + images
                messages[i].content = {
                    { type = "text", text = content },
                    unpack(formatted_images)
                }
            end
            injected = true
            break
        end
    end

    -- EDGE CASE: if no user-role message found, prepend one
    if not injected then
        table.insert(messages, 1, {
            role = "user",
            content = {
                { type = "text", text = "[SYSTEM: Images attached]" },
                unpack(formatted_images)
            }
        })
    end

    -- Update last_sent_image_hashes with newly sent images
    for _, img in ipairs(new_images) do
        local h = img.hash or ""
        if h ~= "" then ctx.last_sent_image_hashes[h] = true end
    end

    -- Calculate total image tokens using OpenAI tile-based model
    -- Low-res (short side < 768px, both <= 2048px): 85 tokens flat
    -- High-res: 85 + 170 * num_tiles (each tile is 512x512)
    -- We estimate from base64 size: raw_bytes ≈ b64_len * 0.75
    -- Approximate pixels from raw bytes assuming 3 bytes/pixel (RGB): pixels ≈ raw_bytes / 3
    -- Tiles ≈ ceil(sqrt(pixels) / 512)^2, capped at 16 (2048x2048 max)
    local total_image_tokens = 0
    for _, img in ipairs(new_images) do
        local b64_len = #(img.base64_data or "")
        local raw_bytes = math.floor(b64_len * 0.75)
        local approx_pixels = math.max(1, math.floor(raw_bytes / 3))
        -- Estimate dimensions assuming square-ish image
        local side = math.ceil(math.sqrt(approx_pixels))
        -- Determine if low-res or high-res
        -- Low-res heuristic: if estimated side < 768, treat as low-res
        if side < 768 then
            total_image_tokens = total_image_tokens + 85
        else
            -- High-res: estimate number of 512x512 tiles
            local tiles_x = math.ceil(side / 512)
            local tiles_y = math.ceil(side / 512)
            -- Cap at 4x4 = 16 tiles (OpenAI limit for 2048x2048)
            tiles_x = math.min(tiles_x, 4)
            tiles_y = math.min(tiles_y, 4)
            local num_tiles = tiles_x * tiles_y
            total_image_tokens = total_image_tokens + 85 + (170 * num_tiles)
        end
    end
    local inject_elapsed = socket.gettime() - t_inject
    logger.info(string.format("[IMAGE DIAG] inject_images_into_messages completed: %.3fs elapsed", inject_elapsed))
    return messages, total_image_tokens
end
-- ============================================================================
-- IMAGE SUMMARY (for agent awareness in recency block)
-- ============================================================================
function M.get_image_summary(ctx)
    if not ctx.images or #ctx.images == 0 then
        return ""
    end
    local parts = {}
    local total_b64 = 0
    for _, img in ipairs(ctx.images) do
        total_b64 = total_b64 + #(img.base64_data or "")
    end
    table.insert(parts, string.format("[VISUAL CONTEXT: %d image(s) loaded, ~%.1f KB total base64]", #ctx.images, total_b64 / 1024))
    -- List up to 5 image paths/names
    local max_list = math.min(#ctx.images, 5)
    for i = 1, max_list do
        local img = ctx.images[i]
        local name = img.path or ("image_" .. i)
        -- Extract just filename
        name = name:match("^.*/(.+)$") or name
        local sz = #(img.base64_data or "")
        table.insert(parts, string.format("  - %s (%.1f KB, %s)", name, sz / 1024, img.mime_type or "unknown"))
    end
    if #ctx.images > 5 then
        table.insert(parts, string.format("  ... and %d more", #ctx.images - 5))
    end
    return table.concat(parts, "\n")
end
return M