local patcher_core = require("patcher_core")
local diff = require("patcher.diff")
local matcher = require("patcher.matcher")
local M = {}
function M.apply_patch(original_content, llm_response)
    if not original_content then return false, "No content provided" end
    local start_time = os.clock()
    local TIMEOUT_SECONDS = 5
    local content = original_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local response = llm_response:gsub("\r\n", "\n"):gsub("\r", "\n")
    local changes_count = 0
    local errors = {}
    local original_lines = diff.to_lines(content)
    local file_lines = diff.to_lines(content)
    local response_lines = diff.to_lines(response)
    local state = matcher.STATE_OUTSIDE
    local search_lines = {}
    local replace_lines = {}
    local blocks = {}
    for i = 1, #response_lines do
        local line = response_lines[i]
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if state == matcher.STATE_OUTSIDE then
            if trimmed == "<<<<<<< SEARCH" then
                state = matcher.STATE_IN_SEARCH
                search_lines = {}
                replace_lines = {}
            end
        elseif state == matcher.STATE_IN_SEARCH then
            if trimmed == "=======" then
                state = matcher.STATE_IN_REPLACE
            else
                table.insert(search_lines, line)
            end
        elseif state == matcher.STATE_IN_REPLACE then
            if trimmed:match("^>>>>>>>") then
                table.insert(blocks, { search_lines = search_lines, replace_lines = replace_lines })
                state = matcher.STATE_OUTSIDE
            elseif trimmed == "<<<<<<< SEARCH" then
                state = matcher.STATE_IN_SEARCH
                search_lines = {}
                replace_lines = {}
            else
                table.insert(replace_lines, line)
            end
        end
    end
    if state == matcher.STATE_IN_REPLACE and #search_lines > 0 then
        table.insert(blocks, { search_lines = search_lines, replace_lines = replace_lines })
    end
    for _, block in ipairs(blocks) do
        local s_lines = matcher.strip_all_empty(block.search_lines)
        local r_lines = matcher.strip_all_empty(block.replace_lines)
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
                local s_line, e_line, err_msg = patcher_core.find_unique_fuzzy_block(file_lines, s_lines)
                if s_line and e_line then
                    local new_file_lines = {}
                    for k = 1, s_line - 1 do
                        new_file_lines[#new_file_lines + 1] = file_lines[k]
                    end
                    for k = 1, #r_lines do
                        new_file_lines[#new_file_lines + 1] = r_lines[k]
                    end
                    for k = e_line + 1, #file_lines do
                        new_file_lines[#new_file_lines + 1] = file_lines[k]
                    end
                    file_lines = new_file_lines
                    changes_count = changes_count + 1
                elseif err_msg and err_msg:match("^AMBIGUOUS") then
                    local snippet = s_str:sub(1, 100):gsub("\n", " ")
                    if #snippet > 50 then snippet = snippet:sub(1, 50) .. "..." end
                    table.insert(errors, string.format("FAILED BLOCK: '%s' -> AMBIGUOUS MATCH: Found multiple occurrences. Add more context lines to make the match unique.", snippet))
                else
                    local matches = matcher.find_all_matches_skip_empty(file_lines, s_lines)
                    if #matches > 0 then
                        for m = #matches, 1, -1 do
                            local mi = matches[m]
                            local fidx = mi
                            local sidx = 1
                            local span_end = mi
                            while sidx <= #s_lines and fidx <= #file_lines do
                                if file_lines[fidx]:match("^%s*$") then
                                    fidx = fidx + 1
                                elseif diff.fuzzy_line_eq(file_lines[fidx], s_lines[sidx]) then
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
                        local norm_s_lines = {}
                        for _, sl in ipairs(s_lines) do
                            table.insert(norm_s_lines, sl:gsub("^%s+", ""):gsub("%s+$", ""))
                        end
                        local norm_matches = matcher.find_all_matches_skip_empty(file_lines, norm_s_lines)
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
                                        local file_norm = file_lines[fidx]:gsub("^%s+", ""):gsub("%s+$", "")
                                        if file_norm == norm_s_lines[sidx] then
                                            sidx = sidx + 1
                                            span_end = fidx
                                            fidx = fidx + 1
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
                    end
                end
            end
        end
    end
    if changes_count > 0 then
        local diff_str = diff.generate_unified_diff(original_lines, file_lines)
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
