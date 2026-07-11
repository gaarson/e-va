local M = {}
local patcher_core = require("patcher_core")

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
-- State constants for the line-based parser
local STATE_OUTSIDE = 0
local STATE_IN_SEARCH = 1
local STATE_IN_REPLACE = 2

function M.apply_patch(original_content, llm_response)
    if not original_content then return false, "No content provided" end

    local content = original_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local response = llm_response:gsub("\r\n", "\n"):gsub("\r", "\n")

    local changes_count = 0
    local errors = {}
    local file_lines = to_lines(content)

    -- Phase 1: Line-based state-machine parsing of SEARCH/REPLACE blocks
    local response_lines = to_lines(response)
    local state = STATE_OUTSIDE
    local search_lines = {}
    local replace_lines = {}
    local blocks = {} -- array of { search_lines={}, replace_lines={} }

    for i = 1, #response_lines do
        local line = response_lines[i]
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")

        if state == STATE_OUTSIDE then
            if trimmed == "<<<<<<< SEARCH" then
                state = STATE_IN_SEARCH
                search_lines = {}
                replace_lines = {}
            end

        elseif state == STATE_IN_SEARCH then
            if trimmed == "=======" then
                state = STATE_IN_REPLACE
            else
                table.insert(search_lines, line)
            end

        elseif state == STATE_IN_REPLACE then
            if trimmed:match("^>>>>>>>") then
                -- End of block: store it
                table.insert(blocks, { search_lines = search_lines, replace_lines = replace_lines })
                state = STATE_OUTSIDE
            elseif trimmed == "<<<<<<< SEARCH" then
                -- FIX: Если начался новый блок без закрытия предыдущего, сбрасываем состояние и начинаем новый поиск
                state = STATE_IN_SEARCH
                search_lines = {}
                replace_lines = {}
            else
                table.insert(replace_lines, line)
            end
        end
    end

    -- FIX: На случай, если ИИ забыл поставить финальный >>>>>>> REPLACE
    if state == STATE_IN_REPLACE and #search_lines > 0 then
        table.insert(blocks, { search_lines = search_lines, replace_lines = replace_lines })
    end

    -- Phase 2: Apply each parsed block to file_lines


    -- FIX: Strip leading/trailing empty lines from search and replace blocks.

    -- LLM output often includes blank lines around SEARCH/REPLACE content.

    -- These empty lines cause fuzzy matching to fail in the C module.

    local function strip_empty_edges(lns)

        local start = 1

        local finish = #lns

        while start <= finish and lns[start]:match("^%s*$") do start = start + 1 end

        while finish >= start and lns[finish]:match("^%s*$") do finish = finish - 1 end

        if start > finish then return {} end

        local result = {}

        for i = start, finish do result[#result + 1] = lns[i] end

        return result

    end


    for _, block in ipairs(blocks) do
        local s_lines = block.search_lines
        local r_lines = block.replace_lines
        s_lines = strip_empty_edges(s_lines)
        r_lines = strip_empty_edges(r_lines)

        -- Check if search block has any non-empty content
        local has_content = false
        for _, l in ipairs(s_lines) do
            if l:match("%S") then has_content = true; break end
        end

        if not has_content then
            table.insert(errors, "FAILED BLOCK: SEARCH block is empty or whitespace-only.")
        else
            -- Zero-op check: search and replace are identical
            local s_str = table.concat(s_lines, "\n")
            local r_str = table.concat(r_lines, "\n")
            if s_str == r_str then
                table.insert(errors, "FAILED BLOCK: SEARCH and REPLACE blocks are EXACTLY identical. No changes needed. If the file is correct, output ||| COMMAND |||\ntask_complete\n||| END_COMMAND |||.")
            else
                -- Find and apply via C module
                local s_line, e_line, err_msg = patcher_core.find_unique_fuzzy_block(file_lines, s_lines)

                if s_line and e_line then
                    local count_to_remove = e_line - s_line + 1
                    for _ = 1, count_to_remove do
                        table.remove(file_lines, s_line)
                    end

                    for idx = #r_lines, 1, -1 do
                        table.insert(file_lines, s_line, r_lines[idx])
                    end

                    changes_count = changes_count + 1
                else
                    local snippet = s_str:sub(1, 100):gsub("\n", " ")
                    if #snippet > 50 then snippet = snippet:sub(1, 50) .. "..." end
                    local reason = err_msg or "Fuzzy failed in C module"
                    table.insert(errors, string.format("FAILED BLOCK: '%s' -> %s", snippet, reason))
                end
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
