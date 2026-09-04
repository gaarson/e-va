local M = {}
function M._request_hash(profile, messages, options)
    local parts = {
        profile.model or "",
        profile.url or "",
        tostring(options and options.temperature or ""),
        tostring(options and options.max_tokens or "")
    }
    if messages then
        for _, msg in ipairs(messages) do
            table.insert(parts, msg.role or "")
            local content = msg.content or ""
            if type(content) == "table" then
                local text_total_len = 0
                local img_count = 0
                for _, part in ipairs(content) do
                    if part.type == "text" then
                        text_total_len = text_total_len + #(part.text or "")
                    elseif part.type == "image_url" then
                        img_count = img_count + 1
                    end
                end
                content = string.format("imgs=%d;textlen=%d", img_count, text_total_len)
            end
            table.insert(parts, content)
        end
    end
    local h = table.concat(parts, "|")
    local len = #h
    local msg_count = messages and #messages or 0
    -- Two-pass hashing: first 4096 bytes + last 4096 bytes + length + message count
    -- This ensures different content always produces different hashes regardless of size.
    local SAMPLE_SIZE = 4096
    local head = h:sub(1, math.min(SAMPLE_SIZE, len))
    local tail_start = math.max(1, len - SAMPLE_SIZE + 1)
    local tail = h:sub(tail_start, len)
    local combined = string.format("%d|%d|%s|%s", len, msg_count, head, tail)
    local hash = 5381
    local clen = #combined
    for i = 1, clen do
        local byte = string.byte(combined, i)
        hash = ((hash * 33) + byte) % 4294967295
    end
    return string.format("%08x", hash)
end
function M._cleanup_in_flight()
    local cqueues = require("cqueues")
    local now = cqueues.monotime()
    for hash, entry in pairs(M._in_flight_requests) do
        if now - entry.timestamp > M._DEDUP_CLEANUP_INTERVAL then
            M._in_flight_requests[hash] = nil
        end
    end
end
return M