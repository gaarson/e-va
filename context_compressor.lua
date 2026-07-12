local M = {}


-- ============================================================================

-- DEFAULT CONFIGURATION

-- ============================================================================

M.DEFAULT_CONFIG = {
    zone1_size = 10,               -- Recent messages: keep verbatim
    zone2_size = 20,               -- Middle messages: light compression
    max_tool_output_bytes = 4096,  -- Increased from 2048 to 4096 for better context retention
    compress_thinking_blocks = true,
    preserve_errors = true,
    max_shell_head_lines = 10,     -- Increased from 5 to 10
    max_shell_tail_lines = 20,     -- Increased from 10 to 20
    max_file_head_lines = 20,
    max_file_tail_lines = 20,
    max_search_results = 15,
    max_error_output_bytes = 8192, -- Error outputs preserved up to 8KB
}


-- ============================================================================

-- HELPER: Line splitting utility

-- ============================================================================

local function split_lines(text)

    local lines = {}

    for line in text:gmatch("[^\r\n]+") do

        table.insert(lines, line)

    end

    return lines

end


-- ============================================================================

-- 1. compress_assistant_thinking(content)

-- Extract key decisions/actions from <thinking> blocks

-- ============================================================================

function M.compress_assistant_thinking(content, config)
    config = config or M.DEFAULT_CONFIG
    if not config.compress_thinking_blocks then return content end
    local thinking_pattern = "<thinking>(.-)</thinking>"
    local result = content
    -- Check if there are thinking blocks
    if not result:match(thinking_pattern) then
        return content
    end
    local decisions = {}
    result = result:gsub(thinking_pattern, function(thinking_block)
        local lines = split_lines(thinking_block)
        local key_points = {}
        for _, line in ipairs(lines) do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed == "" then end
            -- Extract decision patterns
            if trimmed ~= "" then
                if trimmed:lower():match("decision") or trimmed:lower():match("choose") or trimmed:lower():match("select") then
                    table.insert(key_points, trimmed)
                elseif trimmed:lower():match("conclusion") or trimmed:lower():match("therefore") or trimmed:lower():match("so we") then
                    table.insert(key_points, trimmed)
                elseif trimmed:lower():match("action") or trimmed:lower():match("will") or trimmed:lower():match("need to") then
                    table.insert(key_points, trimmed)
                elseif trimmed:lower():match("important") or trimmed:lower():match("critical") or trimmed:lower():match("must") then
                    table.insert(key_points, trimmed)
                end
            end
        end
        if #key_points > 0 then
            local summary = table.concat(key_points, "; ")
            -- Truncate if too long
            if #summary > 500 then
                summary = summary:sub(1, 497) .. "..."
            end
            table.insert(decisions, summary)
            return "" -- Remove the thinking block
        else
            -- No key points extracted, just note that thinking occurred
            table.insert(decisions, "[Reasoning performed]")
            return ""
        end
    end)
    if #decisions > 0 then
        local prefix = "[THOUGHT SUMMARY: " .. table.concat(decisions, ", ") .. "]"
        -- Remove excessive whitespace left by removal
        result = result:gsub("%s+", " ")
        result = result:gsub("^%s+", "")
        result = result:gsub("%s+$", "")
        result = prefix .. (result ~= "" and " " .. result or "")
    end
    return result
end


-- ============================================================================
-- 2. classify_tool_output(output)
-- Classify output type for adaptive compression
-- ============================================================================
function M.classify_tool_output(output)
    if not output or #output == 0 then return "generic" end
    -- Error outputs: contain error indicators
    if output:match("[Ee][Rr][Rr][Oo][Rr]") or
       output:match("[Ff][Aa][Ii][Ll][Ee][Dd]") or
       output:match("[Pp][Aa][Tt][Cc][Hh] [Ff][Aa][Ii][Ll][Ee][Dd]") or
       output:match("[Dd][Ii][Ss][Kk] [Ee][Rr][Rr][Oo][Rr]") or
       output:match("[Ff][Aa][Tt][Aa][Ll]") or
       output:match("[Tt][Rr][Aa][Cc][Ee][Bb][Aa][Cc][Kk]") or
       output:match("[Ee][Xx][Cc][Ee][Pp][Tt][Ii][Oo][Nn]") then
        return "error"
    end
    -- Shell outputs
    if output:match("^\\[SHELL OUTPUT\\]") or output:match("^\\[SHELL STDOUT") or
       output:match("^\\[SHELL STDERR") or output:match("^\\[SHELL") then
        return "shell"
    end
    -- Search results
    if output:match("^\\[SEARCH RESULTS\\]") or output:match("^=== SEARCH DIGEST ===") or
       output:match("^\\[SEARCH") then
        return "search"
    end
    return "generic"
end
-- ============================================================================
-- 3. compress_tool_output(output)
-- Smart truncation based on output type (adaptive)
-- ============================================================================
function M.compress_tool_output(output, config)
    config = config or M.DEFAULT_CONFIG
    if not output or #output == 0 then return output end
    -- Classify output type for adaptive strategy
    local output_type = M.classify_tool_output(output)
    -- Route to appropriate compression strategy based on classification
    if output_type == "error" then
        -- Error outputs: preserve up to 8KB for debugging
        if #output <= config.max_error_output_bytes then
            return output
        end
        return M._truncate_middle(output, config.max_error_output_bytes)
    elseif output_type == "shell" then
        return M._compress_shell_output(output, config)
    elseif output_type == "search" then
        return M._compress_search_output(output, config)
    else
        -- Generic outputs: use standard truncation
        if #output <= config.max_tool_output_bytes then
            return output
        end
        return M._truncate_middle(output, config.max_tool_output_bytes)
    end
end


-- Shell output: keep head + tail

function M._compress_shell_output(output, config)

    local lines = split_lines(output)

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


-- Search results: keep only matching/highlighted lines

function M._compress_search_output(output, config)

    local lines = split_lines(output)

    local kept = {}


    for _, line in ipairs(lines) do

        -- Keep query headers

        if line:match("^--- Query:") or line:match("^=== SEARCH") or line:match("^%- Query:") then

            table.insert(kept, line)

        -- Keep lines with match indicators (line numbers, colons)

        elseif line:match("^%S+:%d+:") or line:match("^%d+:-") or line:match("^%- ") then

            if #kept < config.max_search_results + 5 then

                table.insert(kept, line)

            end

        -- Keep short informative lines

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


-- Generic/file output: keep head + tail lines

function M._compress_generic_output(output, config)

    local lines = split_lines(output)

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


-- Generic middle truncation

function M._truncate_middle(text, max_bytes)

    local half = math.floor(max_bytes / 2)

    local head = text:sub(1, half)

    local tail = text:sub(-half)

    local omitted = #text - max_bytes

    -- Find line boundaries

    local head_end = head:find("[\r\n]", half)

    local tail_start_pos = tail:find("[\r\n]")

    if head_end then head = head:sub(1, head_end) end

    if tail_start_pos then tail = tail:sub(tail_start_pos) end

    return head .. "\n[..." .. omitted .. " bytes omitted...]\n" .. tail

end


-- ============================================================================

-- 3. compress_history_window(history, config)

-- Tiered compression across zones

-- ============================================================================

function M.compress_history_window(history, config)

    config = config or M.DEFAULT_CONFIG

    if not history or #history == 0 then return history, 0 end


    local total = #history

    local zone1_end = total  -- Zone 1: most recent

    local zone2_end = total - config.zone1_size  -- Zone 2: middle

    local zone3_end = zone2_end - config.zone2_size  -- Zone 3: oldest


    if zone3_end < 1 then zone3_end = 1 end

    if zone2_end < 1 then zone2_end = 1 end


    local compressed_count = 0

    local tokens_saved = 0


    -- Zone 3: Aggressive compression (oldest messages)

    for i = 1, zone3_end - 1 do

        local msg = history[i]

        if msg and msg.content then

            local original_len = #msg.content

            -- Only keep task-critical messages, compress others heavily

            if M._is_task_critical(msg) then

                -- Light compression only

                msg.content = M.compress_assistant_thinking(msg.content, config)

                if msg.content:match("^\\[") then

                    msg.content = M.compress_tool_output(msg.content, config)

                end

            else

                -- Aggressive: replace with summary

                msg.content = M._summarize_message(msg, config)

            end

            tokens_saved = tokens_saved + (original_len - #msg.content)

            compressed_count = compressed_count + 1

        end

    end


    -- Zone 2: Light compression (middle messages)

    for i = zone3_end, zone2_end - 1 do

        local msg = history[i]

        if msg and msg.content then

            local original_len = #msg.content

            msg.content = M.compress_assistant_thinking(msg.content, config)

            if msg.content:match("^\\[") then

                msg.content = M.compress_tool_output(msg.content, config)

            end

            tokens_saved = tokens_saved + (original_len - #msg.content)

            compressed_count = compressed_count + 1

        end

    end


    -- Zone 1: Keep verbatim (most recent)

    -- No compression applied


    return history, compressed_count, tokens_saved

end


-- ============================================================================

-- 4. calculate_compression_ratio(original, compressed)

-- ============================================================================

function M.calculate_compression_ratio(original, compressed)

    if not original or #original == 0 then return 1.0 end

    if not compressed or #compressed == 0 then return 0.0 end

    return #compressed / #original

end


-- ============================================================================

-- 5. is_compressible(msg)

-- Heuristic to determine if compression is beneficial

-- ============================================================================

function M.is_compressible(msg, config)

    config = config or M.DEFAULT_CONFIG

    if not msg or not msg.content then return false end


    local content = msg.content

    local len = #content


    -- Skip short messages (compression overhead not worth it)

    if len < 200 then return false end


    -- Skip messages containing commands (they need to stay intact)

    if content:match("||| COMMAND |||") then return false end


    -- Skip system messages that are short directives

    if msg.role == "system" and len < 500 then return false end


    -- Compressible if it has thinking blocks, large tool output, or is just very long

    if config.compress_thinking_blocks and content:match("<thinking>") then return true end

    if content:match("^\\[SHELL") or content:match("^\\[SEARCH") or content:match("^\\[OUTPUT") or content:match("^\\[RESULT") then

        if len > config.max_tool_output_bytes then return true end

    end


    -- Very long messages are always candidates

    if len > 5000 then return true end


    return false

end


-- ============================================================================

-- INTERNAL HELPERS

-- ============================================================================


-- Determine if a message is task-critical (should be preserved more faithfully)

function M._is_task_critical(msg)

    if not msg then return false end

    local role = msg.role or ""

    local content = msg.content or ""


    -- User questions/task descriptions

    if role == "user" then

        if content:match("^TASK:") or content:match("^QUESTION:") or content:match("%?%s*$") then

            return true

        end

    end


    -- Assistant messages with commands

    if role == "assistant" and content:match("||| COMMAND |||") then

        return true

    end


    -- System messages

    if role == "system" then return true end


    return false

end


-- Create a concise summary of a message for aggressive compression

function M._summarize_message(msg, config)

    local role = msg.role or "unknown"

    local content = msg.content or ""


    -- Extract key info

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


-- ============================================================================

-- BATCH COMPRESS: Apply compression to a single message

-- ============================================================================

function M.compress_message(msg, config)

    config = config or M.DEFAULT_CONFIG

    if not msg or not msg.content then return msg end


    local original_len = #msg.content


    -- Compress thinking blocks

    msg.content = M.compress_assistant_thinking(msg.content, config)


    -- Compress tool outputs

    if msg.content:match("^\\[SHELL") or msg.content:match("^\\[SEARCH") or

       msg.content:match("^\\[OUTPUT") or msg.content:match("^\\[RESULT") or

       msg.content:match("^\\[FILE") then

        msg.content = M.compress_tool_output(msg.content, config)

    end


    return msg

end


return M