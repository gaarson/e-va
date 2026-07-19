local helpers = require("context_compressor.helpers")
local M = {}
function M.compress_assistant_thinking(content, config)
    config = config or helpers.DEFAULT_CONFIG
    if not config.compress_thinking_blocks then return content end
    local thinking_pattern = "<thinking>(.-)</thinking>"
    local result = content
    if not result:match(thinking_pattern) then
        return content
    end
    local decisions = {}
    result = result:gsub(thinking_pattern, function(thinking_block)
        local lines = helpers.split_lines(thinking_block)
        local key_points = {}
        for _, line in ipairs(lines) do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                if trimmed:lower():match("decision") or trimmed:lower():match("choose") or trimmed:lower():match("select") then
                    table.insert(key_points, trimmed)
                elseif trimmed:lower():match("conclusion") or trimmed:lower():match("therefore") or trimmed:lower():match("so we") then
                    table.insert(key_points, trimmed)
                elseif trimmed:lower():match("action") or trimmed:lower():match("will") or trimmed:lower():match("need to") then
                    table.insert(key_points, trimmed)
                elseif trimmed:lower():match("important") or trimmed:lower():match("critical") or trimmed:lower():match("must") then
                    table.insert(key_points, trimmed)
                end
            end
        end
        if #key_points > 0 then
            local summary = table.concat(key_points, "; ")
            if #summary > 500 then
                summary = summary:sub(1, 497) .. "..."
            end
            table.insert(decisions, summary)
            return ""
        else
            table.insert(decisions, "[Reasoning performed]")
            return ""
        end
    end)
    if #decisions > 0 then
        local prefix = "[THOUGHT SUMMARY: " .. table.concat(decisions, ", ") .. "]"
        result = result:gsub("%s+", " ")
        result = result:gsub("^%s+", "")
        result = result:gsub("%s+$", "")
        result = prefix .. (result ~= "" and " " .. result or "")
    end
    return result
end
return M
