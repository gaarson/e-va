local M = {}
local function clean_str(s)
    if not s then return "" end
    return (s:gsub("%s+", ""))
end

local function to_lines(str)
    local t = {}
    local clean = str:gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in clean:gmatch("([^\n]*)\n?") do
        table.insert(t, line)
    end

    if #t > 0 and t[#t] == "" then
        table.remove(t)
    end
    return t
end

-- Enhanced Fuzzy Finder: Checks for AMBIGUITY
-- Returns: start_line, end_line, error_message
local function find_unique_fuzzy_block(content_lines, search_lines)
    if #search_lines == 0 then return nil, nil, "Empty search block" end
    if #content_lines < #search_lines then return nil, nil, "File shorter than search block" end

    local search_clean = {}
    for _, l in ipairs(search_lines) do
        table.insert(search_clean, clean_str(l))
    end

    local matches = {}

    -- Scan the ENTIRE file to find all occurrences
    for i = 1, (#content_lines - #search_lines + 1) do
        local match = true
        for j = 1, #search_lines do
            if clean_str(content_lines[i + j - 1]) ~= search_clean[j] then
                match = false
                break
            end
        end

        if match then
            table.insert(matches, { start = i, finish = (i + #search_lines - 1) })
        end
    end

    if #matches == 0 then
        return nil, nil, "Block not found"
    elseif #matches == 1 then
        return matches[1].start, matches[1].finish, nil
    else
        -- CRITICAL SAFETY: If we found multiple matches, we cannot know which one to replace.
        return nil, nil, string.format("AMBIGUOUS MATCH: Found %d occurrences of this block. Provide more context.", #matches)
    end
end

function M.apply_patch(original_content, llm_response)
    if not original_content then return false, "No content provided" end

    local content = original_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local response = llm_response:gsub("\r\n", "\n"):gsub("\r", "\n")

    local changes_count = 0
    local errors = {}

    local file_lines = to_lines(content)

    for search_block, replace_block in response:gmatch("<<<<<<< SEARCH%s*\n(.-)\n=======[^\n]*\n(.-)\n>>>>>>>[^\n]*") do

        local search_lines = to_lines(search_block)
        local replace_lines = to_lines(replace_block)

        local has_content = false
        for _, l in ipairs(search_lines) do
            if clean_str(l) ~= "" then has_content = true; break end
        end

        if has_content then
            local s_line, e_line, err_msg = find_unique_fuzzy_block(file_lines, search_lines)

            if s_line and e_line then
                local count_to_remove = e_line - s_line + 1
                for _ = 1, count_to_remove do
                    table.remove(file_lines, s_line)
                end

                for i = #replace_lines, 1, -1 do
                    table.insert(file_lines, s_line, replace_lines[i])
                end

                changes_count = changes_count + 1
            else
                local snippet = search_block:sub(1, 100):gsub("\n", " ")
                if #snippet > 50 then snippet = snippet:sub(1,50) .. "..." end
                
                local reason = err_msg or "Fuzzy failed"
                table.insert(errors, string.format("FAILED BLOCK: '%s' -> %s", snippet, reason))
            end
        end
    end

    if changes_count > 0 then
        return true, table.concat(file_lines, "\n"), changes_count
    else
        if #errors > 0 then
            return false, "Patch Failed:\n" .. table.concat(errors, "\n")
        else
            return false, "No valid SEARCH/REPLACE blocks found. Ensure format:\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE"
        end
    end
end

return M
