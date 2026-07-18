
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

    return table.concat(summary_parts, ". ")

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

