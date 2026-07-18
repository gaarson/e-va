
local helpers = require("context_compressor.helpers")


local M = {}


function M.classify_tool_output(output)

    if not output or #output == 0 then return "generic" end

    if output:match("[Ee][Rr][Rr][Oo][Rr]") or

       output:match("[Ff][Aa][Ii][Ll][Ee][Dd]") or

       output:match("[Pp][Aa][Tt][Cc][Hh] [Ff][Aa][Ii][Ll][Ee][Dd]") or

       output:match("[Dd][Ii][Ss][Kk] [Ee][Rr][Rr][Oo][Rr]") or

       output:match("[Ff][Aa][Tt][Aa][Ll]") or

       output:match("[Tt][Rr][Aa][Cc][Ee][Bb][Aa][Cc][Kk]") or

       output:match("[Ee][Xx][Cc][Ee][Pp][Tt][Ii][Oo][Nn]") then

        return "error"

    end

    if output:match("^\\[SHELL OUTPUT\\]") or output:match("^\\[SHELL STDOUT") or

       output:match("^\\[SHELL STDERR") or output:match("^\\[SHELL") then

        return "shell"

    end

    if output:match("^\\[SEARCH RESULTS\\]") or output:match("^=== SEARCH DIGEST ===") or

       output:match("^\\[SEARCH") then

        return "search"

    end

    return "generic"

end


function M.compress_tool_output(output, config)

    config = config or helpers.DEFAULT_CONFIG

    if not output or #output == 0 then return output end

    local output_type = M.classify_tool_output(output)

    if output_type == "error" then

        if #output <= config.max_error_output_bytes then

            return output

        end

        return helpers._truncate_middle(output, config.max_error_output_bytes)

    elseif output_type == "shell" then

        return M._compress_shell_output(output, config)

    elseif output_type == "search" then

        return M._compress_search_output(output, config)

    else

        if #output <= config.max_tool_output_bytes then

            return output

        end

        return helpers._truncate_middle(output, config.max_tool_output_bytes)

    end

end


function M._compress_shell_output(output, config)

    local lines = helpers.split_lines(output)

    local total = #lines

    if total <= (config.max_shell_head_lines + config.max_shell_tail_lines + 2) then

        return output

    end

    local head = {}

    local tail = {}

    for i = 1, config.max_shell_head_lines do

        if lines[i] then table.insert(head, lines[i]) end

    end

    local tail_start = total - config.max_shell_tail_lines + 1

    if tail_start < 1 then tail_start = 1 end

    for i = tail_start, total do

        if lines[i] then table.insert(tail, lines[i]) end

    end

    local omitted = total - config.max_shell_head_lines - config.max_shell_tail_lines

    local result = table.concat(head, "\n") .. "\n[..." .. omitted .. " lines omitted...]\n" .. table.concat(tail, "\n")

    return result

end


function M._compress_search_output(output, config)

    local lines = helpers.split_lines(output)

    local kept = {}

    for _, line in ipairs(lines) do

        if line:match("^--- Query:") or line:match("^=== SEARCH") or line:match("^%- Query:") then

            table.insert(kept, line)

        elseif line:match("^%S+:%d+:") or line:match("^%d+:-") or line:match("^%- ") then

            if #kept < config.max_search_results + 5 then

                table.insert(kept, line)

            end

        elseif #line < 200 and line:match("%S") then

            if #kept < config.max_search_results + 5 then

                table.insert(kept, line)

            end

        end

    end

    local result = table.concat(kept, "\n")

    if #result > config.max_tool_output_bytes then

        result = result:sub(1, config.max_tool_output_bytes) .. "\n[...TRUNCATED...]"

    end

    return result

end


function M._compress_generic_output(output, config)

    local lines = helpers.split_lines(output)

    local total = #lines

    local head_limit = config.max_file_head_lines

    local tail_limit = config.max_file_tail_lines

    if total <= (head_limit + tail_limit + 2) then

        return output

    end

    local head = {}

    local tail = {}

    for i = 1, head_limit do

        if lines[i] then table.insert(head, lines[i]) end

    end

    local tail_start = total - tail_limit + 1

    if tail_start < 1 then tail_start = 1 end

    for i = tail_start, total do

        if lines[i] then table.insert(tail, lines[i]) end

    end

    local omitted = total - head_limit - tail_limit

    local result = table.concat(head, "\n") .. "\n[..." .. omitted .. " lines omitted...]\n" .. table.concat(tail, "\n")

    return result

end


return M

