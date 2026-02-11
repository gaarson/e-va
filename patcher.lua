local M = {}

local function split_lines(text)
    local lines = {}
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    
    local pos = 1
    while true do
        local first, last = text:find("\n", pos)
        if first then
            table.insert(lines, text:sub(pos, first - 1))
            pos = last + 1
        else
            table.insert(lines, text:sub(pos))
            break
        end
    end
    return lines
end

local function normalize_line(line)
    if not line then return "" end
    return line:gsub("%s+", "")
end

function M.apply_search_replace(original_content, llm_response)
    if not original_content or not llm_response then
        return false, "Invalid input"
    end

    local file_lines = split_lines(original_content)
    local changes_made = 0
    local errors = {}

    for search_block, replace_block in llm_response:gmatch("<<<<<<< SEARCH%s*\n(.-)\n=======%s*\n(.-)\n>>>>>>> REPLACE") do
        
        search_block = search_block:gsub("\n$", "")
        replace_block = replace_block:gsub("\n$", "")

        local search_lines = split_lines(search_block)
        local replace_lines = split_lines(replace_block)

        if #search_lines == 0 then
            table.insert(errors, "Empty SEARCH block found (skipped).")
        else
            local match_found = false
            local start_idx = -1

            for i = 1, #file_lines - #search_lines + 1 do
                local match = true
                for j = 1, #search_lines do
                    if normalize_line(file_lines[i + j - 1]) ~= normalize_line(search_lines[j]) then
                        match = false
                        break
                    end
                end

                if match then
                    start_idx = i
                    match_found = true
                    break
                end
            end

            if match_found then
                for _ = 1, #search_lines do
                    table.remove(file_lines, start_idx)
                end
                for j = #replace_lines, 1, -1 do
                    table.insert(file_lines, start_idx, replace_lines[j])
                end
                changes_made = changes_made + 1
            else
                local first_line = search_lines[1] or "???"
                if #first_line > 50 then first_line = first_line:sub(1, 47) .. "..." end
                table.insert(errors, string.format("Block mismatch starting with: '%s'", first_line))
            end
        end
    end

    if changes_made > 0 then
        return true, table.concat(file_lines, "\n"), changes_made
    else
        if #errors > 0 then
            return false, "Patch failed. Errors:\n" .. table.concat(errors, "\n")
        else
            return false, "No valid SEARCH/REPLACE blocks found in LLM response."
        end
    end
end

return M
