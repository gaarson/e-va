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

local function find_fuzzy_block(content_lines, search_lines)
    if #search_lines == 0 then return nil end
    if #content_lines < #search_lines then return nil end

    local search_clean = {}
    for _, l in ipairs(search_lines) do
        table.insert(search_clean, clean_str(l))
    end

    for i = 1, (#content_lines - #search_lines + 1) do
        local match = true
        for j = 1, #search_lines do
            if clean_str(content_lines[i + j - 1]) ~= search_clean[j] then
                match = false
                break
            end
        end

        if match then
            return i, (i + #search_lines - 1)
        end
    end
    return nil
end

function M.apply_patch(original_content, llm_response)
    if not original_content then return false, "No content provided" end

    local content = original_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local response = llm_response:gsub("\r\n", "\n"):gsub("\r", "\n")

    local changes_count = 0
    local errors = {}

    local file_lines = to_lines(content)

    for search_block, replace_block in response:gmatch("<<<<<<< SEARCH%s*\n(.-)\n=======[^\n]*\n(.-)\n>>>>>>>[^\n]*") do
        
        local start_idx = content:find(search_block, 1, true)
        
        local search_lines = to_lines(search_block)
        local replace_lines = to_lines(replace_block)

        local has_content = false
        for _, l in ipairs(search_lines) do 
            if clean_str(l) ~= "" then has_content = true; break end 
        end

        if has_content then
            local s_line, e_line = find_fuzzy_block(file_lines, search_lines)

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
                table.insert(errors, string.format("Block not found (Fuzzy failed): '%s...'", snippet))
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
