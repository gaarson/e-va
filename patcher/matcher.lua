
local diff = require("patcher.diff")


local M = {}


M.STATE_OUTSIDE = 0

M.STATE_IN_SEARCH = 1

M.STATE_IN_REPLACE = 2


function M.find_all_matches_skip_empty(file_lines, search_lines)

    local matches = {}

    local fi = 1

    local iterations = 0

    local max_iterations = 10000

    local first_search_trimmed = search_lines[1]:gsub("^%s+", ""):gsub("%s+$", "")

    local first_search_len = #first_search_trimmed

    while fi <= #file_lines do

        iterations = iterations + 1

        if iterations > max_iterations then

            break

        end

        local file_trimmed = file_lines[fi]:gsub("^%s+", ""):gsub("%s+$", "")

        local file_len = #file_trimmed

        local skip_length = false

        if first_search_len > 0 and file_len > 0 then

            if file_len > first_search_len * 3 or first_search_len > file_len * 3 then

                skip_length = true

            end

        end

        if not skip_length and diff.fuzzy_line_eq(file_lines[fi], search_lines[1]) then

            local si = 2

            local fidx = fi + 1

            local is_match = true

            while si <= #search_lines and fidx <= #file_lines do

                if file_lines[fidx]:match("^%s*$") then

                    fidx = fidx + 1

                elseif diff.fuzzy_line_eq(file_lines[fidx], search_lines[si]) then

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


function M.strip_all_empty(lns)

    local result = {}

    for _, l in ipairs(lns) do

        if not l:match("^%s*$") then

            result[#result + 1] = l

        end

    end

    return result

end


return M

