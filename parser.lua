local M = {}



local function is_masked(pos, intervals)
    if type(pos) ~= "number" then return false, nil end
    for i = 1, #intervals, 2 do
        if pos >= intervals[i] and pos <= intervals[i+1] then
            return true, intervals[i+1]
        end
    end
    return false, nil
end

local function get_masked_intervals(content)
    local intervals = {}
    if type(content) ~= "string" then return intervals end

    
    local function add_mask(s, e)
        if type(s) == "number" and type(e) == "number" then
            local n = #intervals
            intervals[n + 1] = s
            intervals[n + 2] = e
        end
    end

    
    local pos = 1
    while true do
        local s, e = content:find("```", pos, true)
        if not s then break end
        local s_end, e_end = content:find("```", e + 1, true)
        if s_end then
            add_mask(s, e_end)
            pos = e_end + 1
        else
            add_mask(s, #content)
            break
        end
    end

    
    pos = 1
    local HTML_COMMENT_START = "<" .. "!--"
    local HTML_COMMENT_END = "--" .. ">"
    while true do
        local s, e = content:find(HTML_COMMENT_START, pos, true)
        if not s then break end
        local s_end, e_end = content:find(HTML_COMMENT_END, e + 1, true)
        if s_end then
            add_mask(s, e_end)
            pos = e_end + 1
        else
            add_mask(s, #content)
            break
        end
    end

    
    pos = 1
    while true do
        local s, e = content:find("`", pos, true)
        if not s then break end
        
        local masked, m_end = is_masked(s, intervals)
        
        if masked then
            
            pos = m_end + 1 
        else
            local s_end, e_end = content:find("`", e + 1, true)
            local next_newline = content:find("\n", e + 1, true)
            if s_end and (not next_newline or s_end < next_newline) then
                add_mask(s, e_end)
                pos = e_end + 1
            else
                pos = e + 1
            end
        end
    end

    return intervals
end

function M.extract_commands(content)
    if type(content) ~= "string" or #content == 0 then
        return function() return nil end
    end

    local intervals = get_masked_intervals(content)
    local OPEN_TAG = "<cmd>"
    local CLOSE_TAG = "</cmd>"
    local open_len = #OPEN_TAG
    local close_len = #CLOSE_TAG
    local pos = 1
    local len = #content

    return function()
        while pos <= len do
            local s, e
            
            
            while true do
                s, e = content:find(OPEN_TAG, pos, true)
                if not s then return nil end

                local masked, mask_end = is_masked(s, intervals)
                if not masked then break end
                pos = mask_end + 1 
            end

            local payload_start = e + 1
            local depth = 1
            local scan_pos = payload_start

            while scan_pos <= len and depth > 0 do
                local next_open = scan_pos
                while true do
                    local so, eo = content:find(OPEN_TAG, next_open, true)
                    if not so then next_open = nil; break end

                    local masked, m_end = is_masked(so, intervals)
                    if not masked then next_open = so; break end
                    next_open = m_end + 1
                end

                local next_close = scan_pos
                while true do
                    local sc, ec = content:find(CLOSE_TAG, next_close, true)
                    if not sc then next_close = nil; break end

                    local masked, m_end = is_masked(sc, intervals)
                    if not masked then next_close = sc; break end
                    next_close = m_end + 1
                end

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
    if type(commands) ~= "table" or #commands == 0 then return "" end
    local parts = {}
    for _, v in ipairs(commands) do
        parts[#parts + 1] = "<cmd>" .. tostring(v) .. "</cmd>"
    end
    return table.concat(parts, "\n")
end

return M
