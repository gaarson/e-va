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
    local preserve_errors = (config and config.preserve_errors_in_compression ~= false) or true
    local head = {}
    local tail = {}
    local preserved_errors = {}
    for i = 1, config.max_shell_head_lines do
        if lines[i] then table.insert(head, lines[i]) end
    end
    local tail_start = total - config.max_shell_tail_lines + 1
    if tail_start < 1 then tail_start = 1 end
    for i = tail_start, total do
        if lines[i] then table.insert(tail, lines[i]) end
    end
    -- Preserve error/warning lines from the middle section
    if preserve_errors then
        for i = config.max_shell_head_lines + 1, tail_start - 1 do
            if lines[i] then
                local trimmed = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed ~= "" and (
                    trimmed:match("[Ee][Rr][Rr][Oo][Rr]") or
                    trimmed:match("[Ff][Aa][Ii][Ll][Ee][Dd]") or
                    trimmed:match("[Ww][Aa][Rr][Nn][Ii][Nn][Gg]") or
                    trimmed:match("^stderr:") or
                    trimmed:match("^error:") or
                    trimmed:match("^[Ww]arning:") or
                    trimmed:match("^[Ff]ailed:") or
                    trimmed:match("[Pp][Aa][Tt][Cc][Hh] [Ff][Aa][Ii][Ll][Ee][Dd]") or
                    trimmed:match("[Dd][Ii][Ss][Kk] [Ee][Rr][Rr][Oo][Rr]")
                ) then
                    if #trimmed > 150 then trimmed = trimmed:sub(1, 147) .. "..." end
                    preserved_errors[#preserved_errors + 1] = trimmed
                end
            end
        end
    end
    local omitted = total - config.max_shell_head_lines - config.max_shell_tail_lines
    local result = table.concat(head, "\n") .. "\n[..." .. omitted .. " lines omitted...]"
    if #preserved_errors > 0 then
        -- Limit preserved errors to 5
        local err_limit = math.min(#preserved_errors, 5)
        result = result .. "\n[PRESERVED ERRORS/WARNINGS]\n"
        for i = 1, err_limit do
            result = result .. preserved_errors[i] .. "\n"
        end
        if #preserved_errors > err_limit then
            result = result .. string.format("(%d more error(s) omitted)\n", #preserved_errors - err_limit)
        end
    end
    result = result .. table.concat(tail, "\n")
    return result
end
function M._compress_search_output(output, config)
    local lines = helpers.split_lines(output)
    local kept = {}
    local file_paths = {}
    for _, line in ipairs(lines) do
        if line:match("^--- Query:") or line:match("^=== SEARCH") or line:match("^%- Query:") then
            table.insert(kept, line)
        elseif line:match("^%S+:%d+:") or line:match("^%d+:-") or line:match("^%- ") then
            if #kept < config.max_search_results + 5 then
                table.insert(kept, line)
            end
            -- Extract file paths from search results
            local fp = line:match("^([^:%s]+%.[A-Za-z0-9_]+)")
            if fp then
                file_paths[#file_paths + 1] = fp
            end
        elseif #line < 200 and line:match("%S") then
            if #kept < config.max_search_results + 5 then
                table.insert(kept, line)
            end
        end
    end
    local result = table.concat(kept, "\n")
    -- Append preserved file paths
    if #file_paths > 0 then
        local seen = {}
        local unique = {}
        for _, f in ipairs(file_paths) do
            if not seen[f] then
                seen[f] = true
                unique[#unique + 1] = f
            end
        end
        result = result .. "\n[SEARCH FILE PATHS]\n" .. table.concat(unique, ", ")
    end
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
    local preserve_errors = (config and config.preserve_errors_in_compression ~= false) or true
    local head = {}
    local tail = {}
    local preserved_errors = {}
    local file_paths = {}
    for i = 1, head_limit do
        if lines[i] then table.insert(head, lines[i]) end
    end
    local tail_start = total - tail_limit + 1
    if tail_start < 1 then tail_start = 1 end
    for i = tail_start, total do
        if lines[i] then table.insert(tail, lines[i]) end
    end
    -- Preserve error lines and extract file paths from middle section
    if preserve_errors then
        for i = head_limit + 1, tail_start - 1 do
            if lines[i] then
                local trimmed = lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed ~= "" and (
                    trimmed:match("[Ee][Rr][Rr][Oo][Rr]") or
                    trimmed:match("[Ff][Aa][Ii][Ll][Ee][Dd]") or
                    trimmed:match("[Ww][Aa][Rr][Nn][Ii][Nn][Gg]")
                ) then
                    if #trimmed > 150 then trimmed = trimmed:sub(1, 147) .. "..." end
                    preserved_errors[#preserved_errors + 1] = trimmed
                end
                -- Extract file paths
                local fp = trimmed:match("([^:%s]+%.[A-Za-z0-9_]+)")
                if fp then
                    file_paths[#file_paths + 1] = fp
                end
            end
        end
    end
    local omitted = total - head_limit - tail_limit
    local result = table.concat(head, "\n") .. "\n[..." .. omitted .. " lines omitted...]"
    if #preserved_errors > 0 then
        local err_limit = math.min(#preserved_errors, 5)
        result = result .. "\n[PRESERVED ERRORS/WARNINGS]\n"
        for i = 1, err_limit do
            result = result .. preserved_errors[i] .. "\n"
        end
        if #preserved_errors > err_limit then
            result = result .. string.format("(%d more error(s) omitted)\n", #preserved_errors - err_limit)
        end
    end
    if #file_paths > 0 then
        local seen = {}
        local unique = {}
        for _, f in ipairs(file_paths) do
            if not seen[f] then
                seen[f] = true
                unique[#unique + 1] = f
            end
        end
        result = result .. "\n[FILE PATHS]\n" .. table.concat(unique, ", ")
    end
    result = result .. "\n" .. table.concat(tail, "\n")
    return result
end
return M
