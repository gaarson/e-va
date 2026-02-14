local M = {}

local function split_lines(text)
    local lines = {}
    if not text then return lines end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in text:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end
    if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
    return lines
end

-- Нормализация: trim + сжатие внутренних пробелов в один
local function normalize(line)
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    return trimmed:gsub("%s+", " ")
end

function M.apply_search_replace(original_content, llm_response)
    if not original_content or not llm_response then
        return false, "Invalid input"
    end

    local file_lines = split_lines(original_content)
    local changes_applied = 0
    local errors = {}

    for search_block, replace_block in llm_response:gmatch("<<<<<<< SEARCH%s*\n(.-)\n=======%s*\n(.-)\n>>>>>>> REPLACE") do

        local should_process = true
        search_block = search_block:gsub("\n$", "")
        replace_block = replace_block:gsub("\n$", "")

        local search_lines = split_lines(search_block)
        local replace_lines = split_lines(replace_block)

        if #search_lines == 0 then
            table.insert(errors, "Empty SEARCH block.")
            should_process = false
        end

        if should_process then
            local candidates = {}
            for i = 1, #file_lines - #search_lines + 1 do
                local match = true
                for j = 1, #search_lines do
                    if normalize(file_lines[i + j - 1]) ~= normalize(search_lines[j]) then
                        match = false
                        break
                    end
                end
                if match then table.insert(candidates, i) end
            end

            if #candidates == 0 then
                table.insert(errors, string.format(
                    "SEARCH block not found.\nLooking for:\n'%s'...",
                    search_lines[1] or "?"
                ))
            elseif #candidates > 1 then
                table.insert(errors, string.format(
                    "Ambiguous SEARCH block! Found %d occurrences (lines %s).",
                    #candidates, table.concat(candidates, ", ")
                ))
            else
                local start_idx = candidates[1]
                for _ = 1, #search_lines do table.remove(file_lines, start_idx) end
                for k = #replace_lines, 1, -1 do
                    table.insert(file_lines, start_idx, replace_lines[k])
                end
                changes_applied = changes_applied + 1
            end
        end
    end

    if changes_applied > 0 then
        return true, table.concat(file_lines, "\n"), changes_applied
    else
        return false, "Patch Failed:\n" .. table.concat(errors, "\n")
    end
end

return M
