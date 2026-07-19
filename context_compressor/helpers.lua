local M = {}
M.DEFAULT_CONFIG = {
    zone1_size = 10,
    zone2_size = 20,
    max_tool_output_bytes = 4096,
    compress_thinking_blocks = true,
    preserve_errors = true,
    max_shell_head_lines = 10,
    max_shell_tail_lines = 20,
    max_file_head_lines = 20,
    max_file_tail_lines = 20,
    max_search_results = 15,
    max_error_output_bytes = 8192,
}
local function split_lines(text)
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    return lines
end
function M._is_task_critical(msg)
    if not msg then return false end
    local role = msg.role or ""
    local content = msg.content or ""
    if role == "user" then
        if content:match("^TASK:") or content:match("^QUESTION:") or content:match("%?%s*$") then
            return true
        end
    end
    if role == "assistant" and content:match("||| COMMAND |||") then
        return true
    end
    if role == "system" then return true end
    return false
end
function M._extract_critical_entities(content)
    local entities = { files = {}, errors = {}, tools = {}, functions = {}, decisions = {} }
    if not content or #content == 0 then return entities end
    -- Extract file paths (e.g., src/file.lua, /path/to/file, file.c, file.h)
    for fp in content:gmatch("([A-Za-z0-9_./%-]+%.[A-Za-z0-9_]+)") do
        if fp:match("%.[A-Za-z]+$") and not fp:match("^http") and not fp:match("^https") then
            entities.files[#entities.files + 1] = fp
        end
    end
    -- Deduplicate files
    local seen_files = {}
    local unique_files = {}
    for _, f in ipairs(entities.files) do
        if not seen_files[f] then
            seen_files[f] = true
            unique_files[#unique_files + 1] = f
        end
    end
    entities.files = unique_files
    -- Extract error messages (lines with ERROR, FAILED, FAILURE, error:, failed:)
    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and (
            trimmed:match("[Ee][Rr][Rr][Oo][Rr]") or
            trimmed:match("[Ff][Aa][Ii][Ll][Ee][Dd]") or
            trimmed:match("[Ff][Aa][Ii][Ll][Uu][Rr][Ee]") or
            trimmed:match("^error:") or
            trimmed:match("^failed:") or
            trimmed:match("^[Pp][Aa][Tt][Cc][Hh] [Ff][Aa][Ii][Ll][Ee][Dd]") or
            trimmed:match("^[Dd][Ii][Ss][Kk] [Ee][Rr][Rr][Oo][Rr]")
        ) then
            -- Truncate long error lines
            if #trimmed > 120 then trimmed = trimmed:sub(1, 117) .. "..." end
            entities.errors[#entities.errors + 1] = trimmed
        end
    end
    -- Deduplicate errors
    local seen_errors = {}
    local unique_errors = {}
    for _, e in ipairs(entities.errors) do
        if not seen_errors[e] then
            seen_errors[e] = true
            unique_errors[#unique_errors + 1] = e
        end
    end
    entities.errors = unique_errors
    -- Extract tool names and status
    for tool_match in content:gmatch("%[([A-Z_]+)%]") do
        entities.tools[#entities.tools + 1] = tool_match
    end
    for tool_match in content:gmatch("%[([A-Za-z_]+ OUTPUT)%]") do
        entities.tools[#entities.tools + 1] = tool_match
    end
    -- Deduplicate tools
    local seen_tools = {}
    local unique_tools = {}
    for _, t in ipairs(entities.tools) do
        if not seen_tools[t] then
            seen_tools[t] = true
            unique_tools[#unique_tools + 1] = t
        end
    end
    entities.tools = unique_tools
    -- Extract function/method names
    for fn in content:gmatch("(function%s+[A-Za-z_][A-Za-z0-9_.%-%s]*%()") do
        local name = fn:gsub("^function%s+", ""):gsub("%($", "")
        entities.functions[#entities.functions + 1] = name
    end
    for fn in content:gmatch("(static%s+[%w_]+%s+[A-Za-z_][A-Za-z0-9_]*%s*%()") do
        local name = fn:gsub("^static%s+[%w_]+%s+", ""):gsub("%s*%($", "")
        entities.functions[#entities.functions + 1] = name
    end
    -- Deduplicate functions
    local seen_fns = {}
    local unique_fns = {}
    for _, f in ipairs(entities.functions) do
        if not seen_fns[f] then
            seen_fns[f] = true
            unique_fns[#unique_fns + 1] = f
        end
    end
    entities.functions = unique_fns
    -- Extract key decisions (DECISION:, CONCLUSION:, TODO:, FIXME:, NOTE:)
    for line in content:gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and (
            trimmed:match("[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:") or
            trimmed:match("[Cc][Oo][Nn][Cc][Ll][Uu][Ss][Ii][Oo][Nn]:") or
            trimmed:match("[Tt][Oo][Dd][Oo]:") or
            trimmed:match("[Ff][Ii][Xx][Mm][Ee]:") or
            trimmed:match("[Nn][Oo][Tt][Ee]:")
        ) then
            if #trimmed > 120 then trimmed = trimmed:sub(1, 117) .. "..." end
            entities.decisions[#entities.decisions + 1] = trimmed
        end
    end
    return entities
end
function M._summarize_message(msg, config)
    local role = msg.role or "unknown"
    local content = msg.content or ""
    local has_command = content:match("||| COMMAND |||")
    local has_thinking = content:match("<thinking>")
    local tool_output = content:match("^\\[([A-Z_]+)")
    local summary_parts = {}
    table.insert(summary_parts, string.format("[COMPRESSED %s message, %d bytes]", role, #content))
    if has_command then
        local cmd = content:match("||| COMMAND |||%s*(.-)%s*||| END_COMMAND |||")
        if cmd then
            local tool = cmd:match("^([^:]+)")
            table.insert(summary_parts, "Tool: " .. (tool or "unknown"))
        end
    end
    if tool_output then
        table.insert(summary_parts, "Output type: " .. tool_output)
    end
    if has_thinking then
        table.insert(summary_parts, "Contained reasoning")
    end
    -- Extract and preserve critical entities
    local preserve_entities = (config and config.preserve_entities ~= false) or true
    if preserve_entities then
        local entities = M._extract_critical_entities(content)
        -- Append files (limit to 5)
        if #entities.files > 0 then
            local file_list = {}
            for i = 1, math.min(#entities.files, 5) do
                table.insert(file_list, entities.files[i])
            end
            table.insert(summary_parts, "Files: " .. table.concat(file_list, ", "))
        end
        -- Append errors (limit to 3)
        if #entities.errors > 0 then
            local err_list = {}
            for i = 1, math.min(#entities.errors, 3) do
                table.insert(err_list, entities.errors[i])
            end
            table.insert(summary_parts, "Errors: " .. table.concat(err_list, "; "))
        end
        -- Append decisions (limit to 3)
        if #entities.decisions > 0 then
            local dec_list = {}
            for i = 1, math.min(#entities.decisions, 3) do
                table.insert(dec_list, entities.decisions[i])
            end
            table.insert(summary_parts, "Decisions: " .. table.concat(dec_list, "; "))
        end
        -- Append functions (limit to 5)
        if #entities.functions > 0 then
            local fn_list = {}
            for i = 1, math.min(#entities.functions, 5) do
                table.insert(fn_list, entities.functions[i])
            end
            table.insert(summary_parts, "Functions: " .. table.concat(fn_list, ", "))
        end
    end
    local summary = table.concat(summary_parts, ". ")
    -- Enforce 500 char limit
    if #summary > 500 then
        summary = summary:sub(1, 497) .. "..."
    end
    return summary
end
function M._truncate_middle(text, max_bytes)
    local half = math.floor(max_bytes / 2)
    local head = text:sub(1, half)
    local tail = text:sub(-half)
    local omitted = #text - max_bytes
    local head_end = head:find("[\r\n]", half)
    local tail_start_pos = tail:find("[\r\n]")
    if head_end then head = head:sub(1, head_end) end
    if tail_start_pos then tail = tail:sub(tail_start_pos) end
    return head .. "\n[..." .. omitted .. " bytes omitted...]\n" .. tail
end
-- Export split_lines for use by other modules
M.split_lines = split_lines
return M
