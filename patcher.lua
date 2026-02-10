local M = {}

local function split_lines(text)
    local lines = {}
    for line in text:gmatch("([^\r\n]*)\r?\n?") do
        table.insert(lines, line)
    end
    if lines[#lines] == "" then table.remove(lines) end
    return lines
end

local function fuzzy_match_line(line_a, line_b)
    if not line_a or not line_b then return false end
    return line_a:gsub("^%s+", ""):gsub("%s+$", "") == line_b:gsub("^%s+", ""):gsub("%s+$", "")
end

function M.apply_search_replace(original_content, llm_response)
    if not original_content or not llm_response then
        return false, "Invalid input"
    end

    local file_lines = split_lines(original_content)
    local changes_made = 0
    local has_blocks = false

    for search_block, replace_block in llm_response:gmatch("<<<<<<< SEARCH%s*\n(.-)\n=======%s*\n(.-)\n>>>>>>> REPLACE") do
        has_blocks = true

        search_block = search_block:gsub("\n$", "")
        replace_block = replace_block:gsub("\n$", "")

        if search_block ~= replace_block then
            local search_lines = split_lines(search_block)
            local match_found = false
            local start_idx = -1

            for i = 1, #file_lines - #search_lines + 1 do
                local match = true
                for j = 1, #search_lines do
                    if not fuzzy_match_line(file_lines[i + j - 1], search_lines[j]) then
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

            if not match_found then
                return false, "CRITICAL: SEARCH block not found.\nLooking for:\n" .. (search_lines[1] or "???") .. "\n..."
            end

            for _ = 1, #search_lines do
                table.remove(file_lines, start_idx)
            end

            local replace_lines = split_lines(replace_block)
            for j = #replace_lines, 1, -1 do
                table.insert(file_lines, start_idx, replace_lines[j])
            end

            changes_made = changes_made + 1
        end
    end

    if changes_made == 0 then
        if has_blocks then
             return true, original_content, 0
        end
        return false, "No valid SEARCH/REPLACE blocks found. Check formatting (<<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE)."
    end

    return true, table.concat(file_lines, "\n"), changes_made
end

return M
