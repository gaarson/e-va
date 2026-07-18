
local M = {}


function M.fuzzy_line_eq(a, b)

    if not a or not b then return false end

    return a:gsub("^%s+", ""):gsub("%s+$", "") == b:gsub("^%s+", ""):gsub("%s+$", "")

end


function M.generate_unified_diff(old_lines, new_lines, filename)

    filename = filename or "file"

    local diff_lines = {}

    table.insert(diff_lines, "--- " .. filename)

    table.insert(diff_lines, "+++ " .. filename)

    local old_len = #old_lines

    local new_len = #new_lines

    if old_len == new_len then

        local identical = true

        for idx = 1, old_len do

            if not M.fuzzy_line_eq(old_lines[idx], new_lines[idx]) then

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

            local start_j = j

            while j <= new_len do j = j + 1 end

            local hunk_start = math.max(1, start_j - 3)

            local hunk_end = new_len

            table.insert(diff_lines, string.format("@@ -%d,%d +%d,%d @@ ", old_len, 0, hunk_start, hunk_end - hunk_start + 1))

            for k = hunk_start, hunk_end do

                table.insert(diff_lines, "+" .. new_lines[k])

            end

        elseif j > new_len then

            local start_i = i

            while i <= old_len do i = i + 1 end

            local hunk_start = math.max(1, start_i - 3)

            local hunk_end = old_len

            table.insert(diff_lines, string.format("@@ -%d,%d +%d,0 @@ ", hunk_start, hunk_end - hunk_start + 1, new_len))

            for k = hunk_start, hunk_end do

                table.insert(diff_lines, "-" .. old_lines[k])

            end

        else

            if M.fuzzy_line_eq(old_lines[i], new_lines[j]) then

                i = i + 1

                j = j + 1

            else

                local ctx_before = 3

                local old_start = i

                local new_start = j

                local hunk_iters = 0

                local max_hunk_iters = 1000

                while i <= old_len do

                    hunk_iters = hunk_iters + 1

                    if hunk_iters > max_hunk_iters then break end

                    local found = false

                    for k = j, math.min(j + 3, new_len) do

                        if M.fuzzy_line_eq(old_lines[i], new_lines[k]) then

                            found = true

                            break

                        end

                    end

                    if found then break end

                    i = i + 1

                end

                while j <= new_len do

                    hunk_iters = hunk_iters + 1

                    if hunk_iters > max_hunk_iters then break end

                    local found = false

                    for k = i, math.min(i + 3, old_len) do

                        if M.fuzzy_line_eq(new_lines[j], old_lines[k]) then

                            found = true

                            break

                        end

                    end

                    if found then break end

                    j = j + 1

                end

                local old_end = i - 1

                local new_end = j - 1

                local ctx_old_start = math.max(1, old_start - ctx_before)

                local ctx_new_start = math.max(1, new_start - ctx_before)

                table.insert(diff_lines, string.format("@@ -%d,%d +%d,%d @@ ", ctx_old_start, old_end - ctx_old_start + 1, ctx_new_start, new_end - ctx_new_start + 1))

                for k = ctx_old_start, old_start - 1 do

                    table.insert(diff_lines, " " .. old_lines[k])

                end

                for k = old_start, old_end do

                    table.insert(diff_lines, "-" .. old_lines[k])

                end

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


function M.to_lines(str)

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


return M

