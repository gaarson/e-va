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
    local hash = 5381
    local len = #h
    local step = math.max(1, math.floor(len / 50000))
    for i = 1, len, step do
        local byte = string.byte(h, i)
        hash = ((hash * 33) + byte) % 4294967295
    end
    return string.format("%08x", hash)
end
function M._cleanup_in_flight()
    local socket = require("socket")
    local now = socket.gettime()
    for hash, entry in pairs(M._in_flight_requests) do
        if now - entry.timestamp > M._DEDUP_CLEANUP_INTERVAL then
            M._in_flight_requests[hash] = nil
        end
    end
end
return M
