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

return M
