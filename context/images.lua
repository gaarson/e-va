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
            messages[i].content = {
                { type = "text", text = messages[i].content },
                unpack(formatted_images)
            }
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

    -- Calculate total image tokens
    local total_image_tokens = 0
    for _, img in ipairs(new_images) do
        local b64_len = #(img.base64_data or "")
        -- OpenAI vision: low res (<50KB base64) = 85 tokens, high res = ~0.004 tokens/byte
        if b64_len < 50 * 1024 then
            total_image_tokens = total_image_tokens + 85
        else
        total_image_tokens = total_image_tokens + math.ceil(b64_len * tokens_per_byte)
        end
    end
    local inject_elapsed = socket.gettime() - t_inject
    logger.info(string.format("[IMAGE DIAG] inject_images_into_messages completed: %.3fs elapsed", inject_elapsed))
    return messages, total_image_tokens
end


return M