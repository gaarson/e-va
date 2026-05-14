local M = {}

function M.extract_commands(content)
    if not content or #content == 0 then
        return function() return nil end
    end

    local OPEN_TAG = "<cmd>"
    local CLOSE_TAG = "</cmd>"
    local open_len = #OPEN_TAG
    local close_len = #CLOSE_TAG

    local pos = 1
    local len = #content

    return function()
        while pos <= len do
            local s, e = content:find(OPEN_TAG, pos, true)
            if not s then return nil end

            local payload_start = e + 1
            local depth = 1
            local scan_pos = payload_start

            while scan_pos <= len and depth > 0 do
                local next_open = content:find(OPEN_TAG, scan_pos, true)
                local next_close = content:find(CLOSE_TAG, scan_pos, true)

                if next_close and (not next_open or next_close < next_open) then
                    depth = depth - 1
                    if depth == 0 then
                        local payload = content:sub(payload_start, next_close - 1)
                        pos = next_close + close_len
                        return payload
                    end
                    scan_pos = next_close + close_len
                elseif next_open then
                    depth = depth + 1
                    scan_pos = next_open + open_len
                else
                    break
                end
            end
            pos = e + 1
        end
        return nil
    end
end

function M.reconstruct_commands(commands)
    if not commands or #commands == 0 then return "" end
    local parts = {}
    for _, v in ipairs(commands) do
        table.insert(parts, "<cmd>" .. v .. "</cmd>")
    end
    return table.concat(parts, "\n")
end

return M
