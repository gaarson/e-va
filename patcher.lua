
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

-- FIX: Fuzzy line equality (mirrors C fuzzy_streq)

local function fuzzy_line_eq(a, b)

    if not a or not b then return false end

    return a:gsub("^%s+", ""):gsub("%s+$", "") == b:gsub("^%s+", ""):gsub("%s+$", "")

end

-- FIX: Find all occurrences of search_lines in file_lines, skipping empty lines in file

local function find_all_matches_skip_empty(file_lines, search_lines)

    local matches = {}

    local fi = 1

    while fi <= #file_lines do

        if fuzzy_line_eq(file_lines[fi], search_lines[1]) then

            local si = 2

            local fidx = fi + 1

            local is_match = true

            while si <= #search_lines and fidx <= #file_lines do

                if file_lines[fidx]:match("^%s*$") then

                    fidx = fidx + 1

                elseif fuzzy_line_eq(file_lines[fidx], search_lines[si]) then

                    si = si + 1

                    fidx = fidx + 1

                else

                    is_match = false

                    break

                end

            end

            if is_match and si > #search_lines then

                table.insert(matches, fi)

            end

        end

        fi = fi + 1

    end

    return matches

end

-- FIX: Strip ALL empty lines from search/replace blocks

local function strip_all_empty(lns)

    local result = {}

    for _, l in ipairs(lns) do

        if not l:match("^%s*$") then

            result[#result + 1] = l

        end

    end

    return result

end

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

    local blocks = {}

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

                table.insert(blocks, { search_lines = search_lines, replace_lines = replace_lines })

                state = STATE_OUTSIDE

            elseif trimmed == "<<<<<<< SEARCH" then

                state = STATE_IN_SEARCH

                search_lines = {}

                replace_lines = {}

            else

                table.insert(replace_lines, line)

            end

        end

    end

    if state == STATE_IN_REPLACE and #search_lines > 0 then

        table.insert(blocks, { search_lines = search_lines, replace_lines = replace_lines })

    end

    -- Phase 2: Apply each parsed block

    for _, block in ipairs(blocks) do

        local s_lines = strip_all_empty(block.search_lines)

        local r_lines = strip_all_empty(block.replace_lines)

        -- Check if search block has any non-empty content

        local has_content = false

        for _, l in ipairs(s_lines) do

            if l:match("%S") then has_content = true; break end

        end

        if not has_content then

            table.insert(errors, "FAILED BLOCK: SEARCH block is empty or whitespace-only.")

        else

            local s_str = table.concat(s_lines, "\n")

            local r_str = table.concat(r_lines, "\n")

            if s_str == r_str then

                table.insert(errors, "FAILED BLOCK: SEARCH and REPLACE blocks are EXACTLY identical. No changes needed.")

            else

                -- Try C module first (fast, exact contiguous match)

                local s_line, e_line, err_msg = patcher_core.find_unique_fuzzy_block(file_lines, s_lines)

                if s_line and e_line then

                    -- Unique match found via C module

                    local count_to_remove = e_line - s_line + 1

                    for _ = 1, count_to_remove do

                        table.remove(file_lines, s_line)

                    end

                    for idx = #r_lines, 1, -1 do

                        table.insert(file_lines, s_line, r_lines[idx])

                    end

                    changes_count = changes_count + 1

                elseif err_msg and err_msg:match("^AMBIGUOUS") then

                    -- Multiple matches: apply to ALL occurrences (reverse order)

                    local matches = find_all_matches_skip_empty(file_lines, s_lines)

                    if #matches > 0 then

                        for m = #matches, 1, -1 do

                            local mi = matches[m]

                            -- Calculate span including empty lines

                            local fidx = mi

                            local sidx = 1

                            local span_end = mi

                            while sidx <= #s_lines and fidx <= #file_lines do

                                if file_lines[fidx]:match("^%s*$") then

                                    fidx = fidx + 1

                                elseif fuzzy_line_eq(file_lines[fidx], s_lines[sidx]) then

                                    sidx = sidx + 1

                                    span_end = fidx

                                    fidx = fidx + 1

                                else

                                    break

                                end

                            end

                            if sidx > #s_lines then

                                local cnt = span_end - mi + 1

                                for _ = 1, cnt do table.remove(file_lines, mi) end

                                for ri = #r_lines, 1, -1 do table.insert(file_lines, mi, r_lines[ri]) end

                                changes_count = changes_count + 1

                            end

                        end

                    else

                        local snippet = s_str:sub(1, 100):gsub("\n", " ")

                        if #snippet > 50 then snippet = snippet:sub(1, 50) .. "..." end

                        table.insert(errors, string.format("FAILED BLOCK: '%s' -> AMBIGUOUS but fallback found no matches", snippet))

                    end

                else

                    -- C module failed: try Lua fallback that skips empty lines

                    local matches = find_all_matches_skip_empty(file_lines, s_lines)

                    if #matches > 0 then

                        for m = #matches, 1, -1 do

                            local mi = matches[m]

                            local fidx = mi

                            local sidx = 1

                            local span_end = mi

                            while sidx <= #s_lines and fidx <= #file_lines do

                                if file_lines[fidx]:match("^%s*$") then

                                    fidx = fidx + 1

                                elseif fuzzy_line_eq(file_lines[fidx], s_lines[sidx]) then

                                    sidx = sidx + 1

                                    span_end = fidx

                                    fidx = fidx + 1

                                else

                                    break

                                end

                            end

                            if sidx > #s_lines then

                                local cnt = span_end - mi + 1

                                for _ = 1, cnt do table.remove(file_lines, mi) end

                                for ri = #r_lines, 1, -1 do table.insert(file_lines, mi, r_lines[ri]) end

                                changes_count = changes_count + 1

                            end

                        end

                    else

                        local snippet = s_str:sub(1, 100):gsub("\n", " ")

                        if #snippet > 50 then snippet = snippet:sub(1, 50) .. "..." end

                        local reason = err_msg or "Fuzzy failed in C module and Lua fallback"

                        table.insert(errors, string.format("FAILED BLOCK: '%s' -> %s", snippet, reason))

                    end

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