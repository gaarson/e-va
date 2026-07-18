
local file_io = require("utils.file_io")


local M = {}


function M.compute_diff(old_content, new_content, label_old, label_new)

    label_old = label_old or "original"

    label_new = label_new or "modified"

    local old_lines = file_io.read_lines_raw(old_content or "")

    local new_lines = file_io.read_lines_raw(new_content or "")

    local max_len = 500

    if #old_lines > max_len or #new_lines > max_len then

        return string.format("--- %s (%d lines)\n+++ %s (%d lines)\n[file too large for inline diff]",

            label_old, #old_lines, label_new, #new_lines)

    end

    local m, n = #old_lines, #new_lines

    local dp = {}

    for i = 0, m do

        dp[i] = {}

        for j = 0, n do

            dp[i][j] = 0

        end

    end

    for i = 1, m do

        for j = 1, n do

            if old_lines[i] == new_lines[j] then

                dp[i][j] = dp[i-1][j-1] + 1

            else

                dp[i][j] = math.max(dp[i-1][j], dp[i][j-1])

            end

        end

    end

    local result = {}

    table.insert(result, "--- " .. label_old)

    table.insert(result, "+++ " .. label_new)

    local changes = {}

    local i, j = m, n

    while i > 0 or j > 0 do

        if i > 0 and j > 0 and old_lines[i] == new_lines[j] then

            table.insert(changes, {type="equal", old=i, new=j, line=old_lines[i]})

            i = i - 1

            j = j - 1

        elseif j > 0 and (i == 0 or dp[i][j-1] >= dp[i-1][j]) then

            table.insert(changes, {type="add", new=j, line=new_lines[j]})

            j = j - 1

        else

            table.insert(changes, {type="del", old=i, line=old_lines[i]})

            i = i - 1

        end

    end

    local fwd = {}

    for idx = #changes, 1, -1 do

        table.insert(fwd, changes[idx])

    end

    local change_indices = {}

    for idx = 1, #fwd do

        if fwd[idx].type ~= "equal" then

            table.insert(change_indices, idx)

        end

    end

    if #change_indices == 0 then

        return "-- No differences"

    end

    local ctx = 3

    local hunk_groups = {}

    local current_group = {start = change_indices[1] - ctx, end_idx = change_indices[1] + ctx}

    for g = 2, #change_indices do

        if change_indices[g] - ctx <= current_group.end_idx + ctx then

            current_group.end_idx = change_indices[g] + ctx

        else

            table.insert(hunk_groups, current_group)

            current_group = {start = change_indices[g] - ctx, end_idx = change_indices[g] + ctx}

        end

    end

    table.insert(hunk_groups, current_group)

    local output_lines = {}

    table.insert(output_lines, "--- " .. label_old)

    table.insert(output_lines, "+++ " .. label_new)

    for _, grp in ipairs(hunk_groups) do

        local s = math.max(1, grp.start)

        local e = math.min(#fwd, grp.end_idx)

        local old_line_num = fwd[s] and fwd[s].old or 1

        local new_line_num = fwd[s] and fwd[s].new or 1

        table.insert(output_lines, string.format("@@ -%d +%d @@", old_line_num, new_line_num))

        for idx = s, e do

            local c = fwd[idx]

            if c.type == "equal" then

                table.insert(output_lines, " " .. c.line)

            elseif c.type == "del" then

                table.insert(output_lines, "-" .. c.line)

            elseif c.type == "add" then

                table.insert(output_lines, "+" .. c.line)

            end

        end

    end

    return table.concat(output_lines, "\n")

end


return M

