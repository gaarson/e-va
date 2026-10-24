-- context/manager.lua
-- Unified context manager: replaces history.lua, orchestrator.lua, strategies.lua.
-- Implements a 4-step pipeline on every add_message call:
--   1. Deduplicate file contexts (keep only latest per path)
--   2. Truncate tool outputs to max bytes
--   3. Sliding window (drop oldest messages beyond limit)
--   4. Token budget check (summarize if over budget)
-- Also provides KB, command dedup, search, thoughts, and utility functions.

local M = {}
local utils = require("utils")
local logger = require("logger")
local config_mod = require("context.config")
local tokenizer = require("context.tokenizer")

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

--- Get the effective max history messages from flow_config.
local function get_max_messages(ctx)
    local fc = ctx.flow_config or {}
    if fc.max_messages then return fc.max_messages end
    if fc.storage and fc.storage.max_history_messages then return fc.storage.max_history_messages end
    return 200
end

--- Get the effective max tool output bytes from flow_config.
local function get_tool_output_cap(ctx)
    local fc = ctx.flow_config or {}
    if fc.tool_output_cap then return fc.tool_output_cap end
    if fc.compression and fc.compression.max_tool_output_bytes then return fc.compression.max_tool_output_bytes end
    return 4096
end

--- Get the effective max history tokens from flow_config.
local function get_max_tokens(ctx)
    local fc = ctx.flow_config or {}
    if fc.max_tokens then return fc.max_tokens end
    if fc.storage and fc.storage.max_history_tokens then return fc.storage.max_history_tokens end
    return 160000
end

-- ============================================================================
-- STEP 1: DEDUPLICATE FILE CONTEXTS
-- ============================================================================

--- Remove <file_context> blocks from older messages when a newer one exists for the same path.
local function _dedup_file_contexts(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history < 2 then return end

    -- Find latest occurrence index for each file_context path
    local latest_occurrence = {}
    for i = 1, #history do
        local msg = history[i]
        if msg and msg.content then
            for path in msg.content:gmatch('<file_context%s+path="([^"]+)"') do
                latest_occurrence[path] = i
            end
        end
    end

    -- Remove stale file_context blocks from older messages
    local removed = 0
    for i = 1, #history do
        local msg = history[i]
        if msg and msg.content and #msg.content > 100 then
            local original = msg.content
            local new_content = msg.content
            for path, latest_idx in pairs(latest_occurrence) do
                if latest_idx > i then
                    new_content = new_content:gsub('<file_context%s+path="' .. path .. '"[^>]-[^<]-</file_context>', '')
                end
            end
            new_content = new_content:gsub("\n\n\n+", "\n\n")
            if new_content ~= original then
                msg.content = utils.trim(new_content)
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        logger.info(string.format("[MANAGER] Dedup file contexts: cleaned %d message(s) for '%s'", removed, agent_name))
    end
end

-- ============================================================================
-- STEP 2: TRUNCATE TOOL OUTPUTS
-- ============================================================================

--- Truncate any tool output content exceeding the cap.
local function _truncate_tool_outputs(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    local cap = get_tool_output_cap(ctx)
    for i = 1, #history do
        local msg = history[i]
        if msg and msg.content then
            -- Tool outputs are stored as user messages with [SHELL, [SEARCH, etc. prefixes
            -- or as assistant messages containing <tool_output> tags
            if msg.role == "user" and (msg.content:match("^%[SHELL") or msg.content:match("^%[SEARCH")
                or msg.content:match("^%[FILE") or msg.content:match("^%[TOOL")) then
                if #msg.content > cap then
                    local truncated = msg.content:sub(1, cap) .. "\n... [truncated]"
                    msg.content = truncated
                end
            elseif msg.role == "assistant" and msg.content:match("<tool_output") then
                -- Truncate individual tool_output blocks
                local new_content = msg.content:gsub(
                    "<tool_output%s+name=\"([^\"]+)\"[^>]*>(.-)</tool_output>",
                    function(name, body)
                        if #body > cap then
                            return string.format('<tool_output name="%s">%s\n... [truncated]</tool_output>', name, body:sub(1, cap))
                        end
                        return string.format('<tool_output name="%s">%s</tool_output>', name, body)
                    end
                )
                if new_content ~= msg.content then
                    msg.content = new_content
                end
            end
        end
    end
end

-- ============================================================================
-- STEP 3: SLIDING WINDOW
-- ============================================================================

--- Drop oldest messages beyond the max_messages limit (keep system prompt at index 1).
local function _sliding_window(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    local max_msgs = get_max_messages(ctx)
    if #history <= max_msgs then return end

    -- Keep first message (system prompt) and drop from the front
    local excess = #history - max_msgs
    for i = 1, excess do
        table.remove(history, 2) -- remove index 2 (first non-system message)
    end
    logger.info(string.format("[MANAGER] Sliding window: dropped %d oldest message(s) for '%s'", excess, agent_name))
end

-- ============================================================================
-- STEP 4: TOKEN BUDGET CHECK
-- ============================================================================

--- If total estimated tokens exceed budget, summarize the oldest messages.
local function _token_budget_check(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history < 10 then return end -- don't summarize very short histories

    local max_tokens = get_max_tokens(ctx)
    local total_chars = 0
    for i = 1, #history do
        local msg = history[i]
        if msg and msg.content then
            total_chars = total_chars + #msg.content
        end
    end

    -- Rough estimate: chars / 4 ≈ tokens
    local estimated_tokens = math.floor(total_chars / 4)
    if estimated_tokens <= max_tokens then return end

    -- Summarize the oldest half (excluding system prompt at index 1)
    local summarize_from = 2
    local summarize_to = math.max(2, math.floor(#history / 2))
    if summarize_to <= summarize_from then return end

    local summary_parts = {}
    for i = summarize_from, summarize_to do
        local msg = history[i]
        if msg and msg.content then
            -- Keep first 200 chars of each message as a digest
            local snippet = msg.content:sub(1, 200)
            table.insert(summary_parts, string.format("[%s]: %s", msg.role, snippet))
        end
    end

    local summary_text = "[SUMMARY OF EARLIER CONVERSATION]\n" .. table.concat(summary_parts, "\n")
    -- Replace summarized messages with a single summary message
    for i = summarize_to, summarize_from, -1 do
        table.remove(history, i)
    end
    table.insert(history, summarize_from, { role = "user", content = summary_text })

    logger.info(string.format("[MANAGER] Token budget: summarized messages %d-%d into digest for '%s'",
        summarize_from, summarize_to, agent_name))
end

-- ============================================================================
-- MESSAGE HISTORY (4-STEP PIPELINE)
-- ============================================================================

function M.add_message(ctx, agent_name, role, content)
    ctx.history[agent_name] = ctx.history[agent_name] or {}
    table.insert(ctx.history[agent_name], { role = role, content = content })

    -- Run the 4-step pipeline
    _dedup_file_contexts(ctx, agent_name)
    _truncate_tool_outputs(ctx, agent_name)
    _sliding_window(ctx, agent_name)
    _token_budget_check(ctx, agent_name)
end

function M.get_history(ctx, agent_name)
    return ctx.history[agent_name] or {}
end

--- Deduplicate consecutive identical messages (role + content).
function M.deduplicate_consecutive_messages(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history < 2 then return 0 end
    local write_idx = 1
    history[1] = history[1]
    for i = 2, #history do
        if history[i].role ~= history[write_idx].role or history[i].content ~= history[write_idx].content then
            write_idx = write_idx + 1
            history[write_idx] = history[i]
        end
    end
    local removed = #history - write_idx
    for i = #history, write_idx + 1, -1 do
        history[i] = nil
    end
    if removed > 0 then
        logger.info(string.format("[MANAGER] Dedup consecutive: removed %d for '%s'", removed, agent_name))
    end
    return removed
end

--- No-op: pruning is now handled by the pipeline in add_message.
function M.prune_history(ctx, agent_name)
    -- Pipeline runs on every add_message; no separate prune needed.
end

--- No-op: zone-based compression removed.
function M.compress_history(ctx, agent_name)
    -- Replaced by _token_budget_check in the pipeline.
end

--- No-op: proactive squash removed (decision #7).
function M.squash_last_mutation(ctx, agent_name)
    return false
end

-- ============================================================================
-- KNOWLEDGE BASE / FILE MANAGEMENT
-- ============================================================================

function M.add_file(ctx, path, content)
    ctx.knowledge_base[path] = content
    ctx.file_states[path] = "READ"
    -- Track access for ranking
    ctx.global_access_counter = (ctx.global_access_counter or 0) + 1
    ctx.file_access_rank[path] = ctx.global_access_counter
end

function M.pin_file(ctx, path)
    if not ctx.knowledge_base[path] then return false end
    ctx.pinned_files[path] = true
    return true
end

function M.unpin_file(ctx, path)
    if not ctx.pinned_files[path] then return false end
    ctx.pinned_files[path] = nil
    return true
end

function M.remove_file(ctx, path)
    local existed = ctx.knowledge_base[path] ~= nil
    ctx.knowledge_base[path] = nil
    ctx.pinned_files[path] = nil
    ctx.file_states[path] = nil
    ctx.file_access_rank[path] = nil
    return existed
end

function M.touch_file(ctx, path)
    -- No-op in new system: file_states is set on add_file.
end

-- ============================================================================
-- TOOL OUTPUTS (RING BUFFER)
-- ============================================================================

function M.add_tool_output(ctx, tool_name, output)
    ctx.recent_tool_outputs = ctx.recent_tool_outputs or {}
    local cap = get_tool_output_cap(ctx)
    -- Truncate individual output if too large
    if #output > cap then
        output = output:sub(1, cap) .. "\n... [truncated]"
    end
    table.insert(ctx.recent_tool_outputs, { tool = tool_name, output = output, ts = os.time() })
    -- Keep last 20 outputs max
    local max_outputs = 20
    while #ctx.recent_tool_outputs > max_outputs do
        table.remove(ctx.recent_tool_outputs, 1)
    end
end

-- ============================================================================
-- TURN TRACKING
-- ============================================================================

function M.track_requested_file(ctx, path)
    ctx.turn_requested_files[path] = true
end

function M.clear_turn_requested_files(ctx)
    ctx.turn_requested_files = {}
end

-- ============================================================================
-- COMMAND DEDUPLICATION
-- ============================================================================

--- Normalize a command for comparison (lowercase, trim whitespace).
local function _normalize_command(cmd)
    if not cmd then return "" end
    local normalized = cmd:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return normalized
end

function M.is_duplicate_command(ctx, cmd)
    local normalized = _normalize_command(cmd)
    -- Check dedup_exceptions: commands matching any exception are never considered duplicates
    local exceptions = ctx.flow_config and ctx.flow_config.command_flow and ctx.flow_config.command_flow.dedup_exceptions or {}
    for _, exc in ipairs(exceptions) do
        if exc:sub(-1) == "*" then
            local prefix = exc:sub(1, -2):lower()
            if normalized:sub(1, #prefix) == prefix then return false end
        else
            if normalized == exc:lower() then return false end
        end
    end
    for _, executed in ipairs(ctx.executed_commands or {}) do
        if _normalize_command(executed) == normalized then
            return true
        end
    end
    return false
end

function M.add_executed_command(ctx, cmd)
    ctx.executed_commands = ctx.executed_commands or {}
    if cmd and cmd ~= "" then
        table.insert(ctx.executed_commands, cmd)
        -- Keep last 50 commands
        while #ctx.executed_commands > 50 do
            table.remove(ctx.executed_commands, 1)
        end
    end
end

-- ============================================================================
-- SQUASH (DEPRECATED — always false in new system)
-- ============================================================================

function M.should_squash(ctx, agent_name)
    return false
end

-- ============================================================================
-- MESSAGE MANIPULATION
-- ============================================================================

function M.drop_last_message(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history == 0 then return false end
    table.remove(history)
    return true
end

function M.replace_last_assistant_message(ctx, agent_name, new_content)
    local history = M.get_history(ctx, agent_name)
    for i = #history, 1, -1 do
        if history[i].role == "assistant" then
            history[i].content = new_content
            return true
        end
    end
    return false
end

-- ============================================================================
-- THOUGHTS
-- ============================================================================

function M.add_thought(ctx, turn, thought_text)
    ctx.thoughts = ctx.thoughts or {}
    -- Clean: strip markdown formatting for storage
    local clean = thought_text:gsub("```[^\n]*\n", ""):gsub("```", "")
    table.insert(ctx.thoughts, { turn = turn, content = clean })
    -- Keep last 50 thoughts
    while #ctx.thoughts > 50 do
        table.remove(ctx.thoughts, 1)
    end
end

function M.get_thoughts_digest(ctx)
    local thoughts = ctx.thoughts or {}
    if #thoughts == 0 then return "" end
    -- Return last 5 thoughts as a digest
    local start_idx = math.max(1, #thoughts - 4)
    local parts = {}
    for i = start_idx, #thoughts do
        local t = thoughts[i]
        if t and t.content then
            table.insert(parts, string.format("Turn %d: %s", t.turn or "?", t.content:sub(1, 300)))
        end
    end
    return table.concat(parts, "\n")
end

-- ============================================================================
-- SEARCH HISTORY
-- ============================================================================

function M.has_searched(ctx, query)
    return ctx.search_history[query] ~= nil
end

function M.add_search_result(ctx, query, result)
    if ctx.search_history[query] == nil then
        ctx.search_history_order = ctx.search_history_order or {}
        table.insert(ctx.search_history_order, query)
    end
    ctx.search_history[query] = result
end

-- ============================================================================
-- OPTIMIZE CONTEXT (replaces orchestrator.lua)
-- ============================================================================
--- Process optimization instructions (parsed JSON table).
function M.optimize_context(ctx, instructions)
    if type(instructions) ~= "table" then return end
    local results = {}
    -- Single file operations
    if instructions.remove_file then
        M.remove_file(ctx, instructions.remove_file)
        table.insert(results, "Removed: " .. instructions.remove_file)
    end
    if instructions.pin_file then
        M.pin_file(ctx, instructions.pin_file)
        table.insert(results, "Pinned: " .. instructions.pin_file)
    end
    if instructions.unpin_file then
        M.unpin_file(ctx, instructions.unpin_file)
        table.insert(results, "Unpinned: " .. instructions.unpin_file)
    end
    -- Batch file operations
    if type(instructions.remove_files) == "table" then
        for _, path in ipairs(instructions.remove_files) do
            M.remove_file(ctx, path)
            table.insert(results, "Removed: " .. path)
        end
    end
    if type(instructions.pin_files) == "table" then
        for _, path in ipairs(instructions.pin_files) do
            M.pin_file(ctx, path)
            table.insert(results, "Pinned: " .. path)
        end
    end
    if type(instructions.unpin_files) == "table" then
        for _, path in ipairs(instructions.unpin_files) do
            M.unpin_file(ctx, path)
            table.insert(results, "Unpinned: " .. path)
        end
    end
    -- Update summary
    if instructions.update_summary then
        ctx.task_summary = utils.trim(instructions.update_summary)
        table.insert(results, "Summary updated.")
    end
    -- Summarize history (deterministic, no LLM)
    if type(instructions.summarize_history) == "table" then
        local sh = instructions.summarize_history
        local agent_name = sh.agent_name or sh[1]
        local keep_count = sh.keep_count or sh[2] or 10
        if agent_name then
            M.summarize_history(ctx, agent_name, keep_count)
            table.insert(results, string.format("History summarized for '%s' (kept %d).", agent_name, keep_count))
        end
    end
    return #results > 0 and table.concat(results, "\n") or "No operations performed."
end

-- ============================================================================
-- SUMMARIZE HISTORY (explicit call)
-- ============================================================================

function M.summarize_history(ctx, agent_name, keep_count)
    local history = M.get_history(ctx, agent_name)
    if not keep_count or keep_count < 1 then keep_count = 3 end
    if #history <= keep_count then return "Nothing to summarize." end
    -- Summarize all but the last keep_count messages
    local summarize_to = #history - keep_count
    if summarize_to < 2 then return "Nothing to summarize." end

    local summary_parts = {}
    for i = 1, summarize_to do
        local msg = history[i]
        if msg and msg.content then
            table.insert(summary_parts, string.format("[%s]: %s", msg.role, msg.content:sub(1, 200)))
        end
    end

    local summary_text = "[SUMMARY]\n" .. table.concat(summary_parts, "\n")
    -- Remove summarized messages and insert summary
    for i = summarize_to, 1, -1 do
        table.remove(history, i)
    end
    table.insert(history, { role = "user", content = summary_text })

    logger.info(string.format("[MANAGER] Summarized %d messages for '%s'", summarize_to, agent_name))
    return string.format("Summarized %d messages into digest.", summarize_to)
end

return M