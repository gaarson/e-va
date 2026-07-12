
local M = {}
local patcher_core = require("patcher_core")
-- Fuzzy line equality (mirrors C fuzzy_streq)

-- Defined early because it's used by generate_unified_diff

local function fuzzy_line_eq(a, b)

    if not a or not b then return false end

    return a:gsub("^%s+", ""):gsub("%s+$", "") == b:gsub("^%s+", ""):gsub("%s+$", "")

end



-- Unified diff generator
function M.generate_unified_diff(old_lines, new_lines, filename)
    filename = filename or "file"
    local diff_lines = {}
    table.insert(diff_lines, "--- " .. filename)
    table.insert(diff_lines, "+++ " .. filename)
    local old_len = #old_lines
    local new_len = #new_lines


    -- Early termination: if identical, return empty

    if old_len == new_len then

        local identical = true

        for idx = 1, old_len do

            if not fuzzy_line_eq(old_lines[idx], new_lines[idx]) then

                identical = false

                break

            end

        end

        if identical then return "" end

    end


    local i = 1
    local j = 1
    local iterations = 0
    local max_iterations = 5000
    while i <= old_len or j <= new_len do
        iterations = iterations + 1
        if iterations > max_iterations then
            return "--- " .. filename .. "\n+++ " .. filename .. "\n@@ content changed @@"
        end
        if i > old_len then
            -- Remaining new lines
            local start_j = j
            while j <= new_len do j = j + 1 end
            local hunk_start = math.max(1, start_j - 3)
            local hunk_end = new_len
            table.insert(diff_lines, string.format("@@ -%d,%d +%d,%d @@ ", old_len, 0, hunk_start, hunk_end - hunk_start + 1))
            for k = hunk_start, hunk_end do
                table.insert(diff_lines, "+" .. new_lines[k])
            end
        elseif j > new_len then
            -- Remaining old lines
            local start_i = i
            while i <= old_len do i = i + 1 end
            local hunk_start = math.max(1, start_i - 3)
            local hunk_end = old_len
            table.insert(diff_lines, string.format("@@ -%d,%d +%d,0 @@ ", hunk_start, hunk_end - hunk_start + 1, new_len))
            for k = hunk_start, hunk_end do
                table.insert(diff_lines, "-" .. old_lines[k])
            end
        else
            -- Check for matching lines
            if fuzzy_line_eq(old_lines[i], new_lines[j]) then
                i = i + 1
                j = j + 1
            else
                -- Found a difference, collect context and changed lines
                local ctx_before = 3
                -- Collect old lines to remove
                local old_start = i
                local new_start = j
                -- Advance past differing region in old (with iteration cap per hunk)
                local hunk_iters = 0
                local max_hunk_iters = 1000
                while i <= old_len do
                    hunk_iters = hunk_iters + 1
                    if hunk_iters > max_hunk_iters then break end
                    -- Check if old_lines[i] matches any upcoming new_lines[j+]
                    local found = false
                    for k = j, math.min(j + 3, new_len) do
                        if fuzzy_line_eq(old_lines[i], new_lines[k]) then
                            found = true
                            break
                        end
                    end
                    if found then break end
                    i = i + 1
                end
                -- Advance past differing region in new (with iteration cap per hunk)
                while j <= new_len do
                    hunk_iters = hunk_iters + 1
                    if hunk_iters > max_hunk_iters then break end
                    local found = false
                    for k = i, math.min(i + 3, old_len) do
                        if fuzzy_line_eq(new_lines[j], old_lines[k]) then
                            found = true
                            break
                        end
                    end
                    if found then break end
                    j = j + 1
                end
                local old_end = i - 1
                local new_end = j - 1
                -- Context window
                local ctx_old_start = math.max(1, old_start - ctx_before)
                local ctx_new_start = math.max(1, new_start - ctx_before)
                table.insert(diff_lines, string.format("@@ -%d,%d +%d,%d @@ ", ctx_old_start, old_end - ctx_old_start + 1, ctx_new_start, new_end - ctx_new_start + 1))
                -- Context before
                for k = ctx_old_start, old_start - 1 do
                    table.insert(diff_lines, " " .. old_lines[k])
                end
                -- Removed lines
                for k = old_start, old_end do
                    table.insert(diff_lines, "-" .. old_lines[k])
                end
                -- Added lines
                for k = new_start, new_end do
                    table.insert(diff_lines, "+" .. new_lines[k])
                end
            end
        end
    end
    if #diff_lines <= 2 then
        return ""
    end
    return table.concat(diff_lines, "\n")
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
-- Store original lines reference for diff generation
local original_lines_ref = nil

-- State constants for the line-based parser

local STATE_OUTSIDE = 0

local STATE_IN_SEARCH = 1

local STATE_IN_REPLACE = 2

-- FIX: Fuzzy line equality (mirrors C fuzzy_streq)


-- FIX: Find all occurrences of search_lines in file_lines, skipping empty lines in file
-- PERFORMANCE: Added max_iterations cap and length-based pre-filter
local function find_all_matches_skip_empty(file_lines, search_lines)
    local matches = {}
    local fi = 1
    local iterations = 0
    local max_iterations = 10000
    -- Pre-compute first search line length for quick filtering
    local first_search_trimmed = search_lines[1]:gsub("^%s+", ""):gsub("%s+$", "")
    local first_search_len = #first_search_trimmed
    while fi <= #file_lines do
        iterations = iterations + 1
        if iterations > max_iterations then
            break
        end
        -- Length-based pre-filter: skip positions where line length ratio exceeds 3x
        local file_trimmed = file_lines[fi]:gsub("^%s+", ""):gsub("%s+$", "")
        local file_len = #file_trimmed
        local skip_length = false
        if first_search_len > 0 and file_len > 0 then
            if file_len > first_search_len * 3 or first_search_len > file_len * 3 then
                skip_length = true
            end
        end
        if not skip_length and fuzzy_line_eq(file_lines[fi], search_lines[1]) then
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
    local start_time = os.clock()
    local TIMEOUT_SECONDS = 5
    local content = original_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local response = llm_response:gsub("\r\n", "\n"):gsub("\r", "\n")
    local changes_count = 0
    local errors = {}
    local original_lines = to_lines(content)
    local file_lines = to_lines(content)
    -- Helper: check timeout
    local function check_timeout()
        if os.clock() - start_time > TIMEOUT_SECONDS then
            return true
        end
        return false
    end

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
                    -- BULK SLICE REPLACEMENT: O(n) instead of O(n*k) with table.remove loop
                    local count_to_remove = e_line - s_line + 1
                    local new_file_lines = {}
                    -- Copy lines before the match
                    for k = 1, s_line - 1 do
                        new_file_lines[#new_file_lines + 1] = file_lines[k]
                    end
                    -- Insert replacement lines
                    for k = 1, #r_lines do
                        new_file_lines[#new_file_lines + 1] = r_lines[k]
                    end
                    -- Copy lines after the match
                    for k = e_line + 1, #file_lines do
                        new_file_lines[#new_file_lines + 1] = file_lines[k]
                    end
                    file_lines = new_file_lines
                    changes_count = changes_count + 1


                elseif err_msg and err_msg:match("^AMBIGUOUS") then


                    -- AMBIGUOUS MATCH: Fail with error (do NOT silently apply to all)


                    local snippet = s_str:sub(1, 100):gsub("\n", " ")


                    if #snippet > 50 then snippet = snippet:sub(1, 50) .. "..." end


                    table.insert(errors, string.format("FAILED BLOCK: '%s' -> AMBIGUOUS MATCH: Found multiple occurrences. Add more context lines to make the match unique.", snippet))



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
                        -- FALLBACK: Whitespace normalization (fuzzy whitespace match)
                        -- Enabled by default (patcher_fuzzy_whitespace = true)
                        local patcher_fuzzy_whitespace = true
                        if patcher_fuzzy_whitespace then
                            -- Create normalized search lines (trim leading/trailing whitespace)
                            local norm_s_lines = {}
                            for _, sl in ipairs(s_lines) do
                                table.insert(norm_s_lines, sl:gsub("^%s+", ""):gsub("%s+$", ""))
                            end
                            -- Retry with normalized lines
                            local norm_matches = find_all_matches_skip_empty(file_lines, norm_s_lines)
                            if #norm_matches > 0 then
                                for m = #norm_matches, 1, -1 do
                                    local mi = norm_matches[m]
                                    local fidx = mi
                                    local sidx = 1
                                    local span_end = mi
                                    while sidx <= #norm_s_lines and fidx <= #file_lines do
                                        if file_lines[fidx]:match("^%s*$") then
                                            fidx = fidx + 1
                                        else
                                            -- Compare normalized versions
                                            local file_norm = file_lines[fidx]:gsub("^%s+", ""):gsub("%s+$", "")
                                            if file_norm == norm_s_lines[sidx] then
                                                sidx = sidx + 1
                                                span_end = fidx
                                                fidx = fidx + 1
                                            else
                                                break
                                            end
                                        end
                                    end
                                    if sidx > #norm_s_lines then
                                        local cnt = span_end - mi + 1
                                        for _ = 1, cnt do table.remove(file_lines, mi) end
                                        for ri = #r_lines, 1, -1 do table.insert(file_lines, mi, r_lines[ri]) end
                                        changes_count = changes_count + 1
                                    end
                                end
                            else
                                local snippet = s_str:sub(1, 100):gsub("\n", " ")
                                if #snippet > 50 then snippet = snippet:sub(1, 50) .. "..." end
                                local reason = err_msg or "Fuzzy failed in C module, Lua fallback, and whitespace normalization"
                                table.insert(errors, string.format("FAILED BLOCK: '%s' -> %s", snippet, reason))
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
    end

    if changes_count > 0 then
        local diff_str = M.generate_unified_diff(original_lines, file_lines)
        return true, table.concat(file_lines, "\n"), changes_count, diff_str
    else

        if #errors > 0 then

            return false, "Patch Failed:\n" .. table.concat(errors, "\n")

        else

            return false, "No valid SEARCH/REPLACE blocks found. Ensure format:\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE"

        end

    end

end

return M