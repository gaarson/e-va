-- context/history.lua
-- History and knowledge-base management extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local utils = require("utils")
local compressor = require("context_compressor")
local logger = require("logger")
local config_mod = require("context.config")
local strategies_mod = require("context.strategies")
local registry = require("tool_registry")
-- ============================================================================
-- MESSAGE HISTORY
-- ============================================================================
function M.add_message(ctx, agent_name, role, content)
    ctx.history[agent_name] = ctx.history[agent_name] or {}
    table.insert(ctx.history[agent_name], { role = role, content = content })
    M.prune_history(ctx, agent_name)
end
function M.get_history(ctx, agent_name)
    return ctx.history[agent_name] or {}
end
function M.deduplicate_consecutive_messages(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history < 2 then return 0 end
    local write_idx = 1
    history[1] = history[1]  -- keep first
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
    -- Secondary pass: remove cross-role duplicates (e.g., user says X, assistant echoes X)
    -- Keep the first occurrence (usually the user message) and remove the echo
    if #history >= 2 then
        local write_idx2 = 1
        history[1] = history[1]
        for i = 2, #history do
            local is_cross_role_dup = false
            if history[i].role ~= history[write_idx2].role and history[i].content == history[write_idx2].content then
                is_cross_role_dup = true
            end
            if not is_cross_role_dup then
                write_idx2 = write_idx2 + 1
                history[write_idx2] = history[i]
            else
                removed = removed + 1
            end
        end
        for i = #history, write_idx2 + 1, -1 do
            history[i] = nil
        end
    end
    if removed > 0 then
        logger.info(string.format("[DEDUP CONSECUTIVE] Removed %d consecutive duplicate message(s) for agent '%s'", removed, agent_name))
    end
    return removed
end
function M.deduplicate_file_contexts(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history < 2 then return 0 end
    local removed = 0
    -- Collect all file_context paths and their most recent message index
    local latest_occurrence = {} -- path -> message index
    for i = 1, #history do
        local msg = history[i]
        if msg and msg.content then
            for path in msg.content:gmatch('<file_context%s+path="([^"]+)"') do
                latest_occurrence[path] = i  -- keep updating to get the latest
            end
        end
    end
    -- Remove <file_context> blocks from older messages where a newer one exists
    for i = 1, #history do
        local msg = history[i]
        if msg and msg.content and #msg.content > 100 then
            local original = msg.content
            -- For each file_context in this message, check if it's the latest occurrence
            local new_content = msg.content
            for path, latest_idx in pairs(latest_occurrence) do
                if latest_idx > i then
                    -- This is an older occurrence; remove the file_context block
                    new_content = new_content:gsub('<file_context%s+path="' .. path .. '"[^>]-[^<]-</file_context>', '')
                end
            end
            -- Clean up extra whitespace
            new_content = new_content:gsub("\n\n\n+", "\n\n")
            if new_content ~= original then
                msg.content = utils.trim(new_content)
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        logger.info(string.format("[DEDUP FILE CONTEXTS] Cleaned %d message(s) with stale file_context blocks for agent '%s'", removed, agent_name))
    end
    return removed
end
function M.prune_history(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    local limits = ctx.flow_config.storage
    local agent_cfg = ctx.config.AGENTS[agent_name]
    local estimate = function(t) return ctx:estimate_tokens(t, agent_cfg) end
    -- STEP 1: Apply compression BEFORE pruning
    if ctx.flow_config.compression and ctx.flow_config.compression.enabled then
        M.compress_history(ctx, agent_name)
    end
    -- STEP 1.5: Remove consecutive duplicate messages
    M.deduplicate_consecutive_messages(ctx, agent_name)
    -- STEP 1.6: Deduplicate file_context blocks (keep only latest occurrence per path)
    M.deduplicate_file_contexts(ctx, agent_name)
    -- STEP 2: Apply importance-weighted pruning
    strategies_mod.PRUNE_STRATEGIES.importance_weighted(history, limits, estimate, config_mod.IMPORTANCE_SCORES)
    -- STEP 3: Squash large patches and outputs
    strategies_mod.PRUNE_STRATEGIES.squash_large_patches(history, limits, estimate)
    strategies_mod.PRUNE_STRATEGIES.squash_large_outputs(history, limits, estimate)
end

function M.compress_history(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history == 0 then return 0 end
    local cfg = ctx.flow_config.compression or {}
    local zone1 = cfg.zone1_size or 10
    local zone2 = cfg.zone2_size or 20
    local total = #history
    local compressed_count = 0
    local tokens_saved = 0
    -- Zone 3: Oldest messages (aggressive compression)
    local zone3_end = math.max(1, total - zone1 - zone2)
    for i = 1, zone3_end do
        local msg = history[i]
        if msg and msg.content and compressor.is_compressible(msg, cfg) then
            local orig_len = #msg.content
            compressor.compress_message(msg, cfg)
            tokens_saved = tokens_saved + (orig_len - #msg.content)
            compressed_count = compressed_count + 1
        end
    end
    -- Zone 2: Middle messages (light compression)
    local zone2_start = zone3_end + 1
    local zone2_end = total - zone1
    for i = zone2_start, zone2_end do
        local msg = history[i]
        if msg and msg.content and compressor.is_compressible(msg, cfg) then
            local orig_len = #msg.content
            compressor.compress_message(msg, cfg)
            tokens_saved = tokens_saved + (orig_len - #msg.content)
            compressed_count = compressed_count + 1
        end
    end
    if compressed_count > 0 then
        logger.info(string.format("[COMPRESSION] Compressed %d messages, saved ~%d bytes", compressed_count, tokens_saved))
    end
    return compressed_count
end
function M.squash_last_mutation(ctx, agent_name)
    if not ctx.flow_config.command_flow.auto_squash_on_mutation then return false end
    local history = M.get_history(ctx, agent_name)
    for i = #history, 1, -1 do
        local msg = history[i]
        if msg.role == "assistant" then
            local original = msg.content or ""
            local squashed = original
            local mutation_files = {}  -- { tool = "patch", file = "src/main.c" }
            -- Dynamic tool detection: parse tool name from command blocks and check manifest.is_mutation
            squashed = squashed:gsub("||| COMMAND |||\n([%w_]+):([^%s\n\r]*)\n([^\n]*(\n[^\n]*)*)\n?||| END_COMMAND |||",
                function(tool_name, file_path, body)
                    local tool = registry.tools[tool_name]
                    if tool and tool.manifest and tool.manifest.is_mutation then
                        table.insert(mutation_files, { tool = tool_name, file = utils.trim(file_path) or "unknown" })
                        return ""
                    end
                    -- Not a mutation tool, keep the command block
                    return "||| COMMAND |||\n" .. tool_name .. ":" .. file_path .. "\n" .. body .. "||| END_COMMAND |||"
                end)
            squashed = utils.trim(squashed:gsub("\n\n+", "\n\n"))
            if original ~= squashed then
                -- Strip command blocks from assistant message, preserving reasoning
                history[i].content = squashed
                -- Build system memory annotation from collected file paths
                local mem_parts = {}
                for _, mf in ipairs(mutation_files) do
                    local action = mf.tool == "patch" and "Patch applied to" or "Mutation applied to"
                    table.insert(mem_parts, string.format("%s '%s' (via %s).", action, mf.file, mf.tool))
                end
                local mem_content = "<system-memory>" .. table.concat(mem_parts, " ") .. "</system-memory>"
                -- Insert a separate system message AFTER the assistant message
                table.insert(history, i + 1, { role = "system", content = mem_content })
                return true
            end
            break
        end
    end
    return false
end
-- ============================================================================
-- KNOWLEDGE BASE & FILE STATE
-- ============================================================================
function M.add_file(ctx, path, content)
    ctx.knowledge_base[path] = content
    ctx.file_states[path] = "READ"
    ctx.global_access_counter = ctx.global_access_counter + 1
    ctx.file_access_rank[path] = ctx.global_access_counter
    ctx.file_access_rank[path .. "_last_turn"] = ctx.current_turn
end
function M.pin_file(ctx, path)
    if ctx.knowledge_base[path] then ctx.pinned_files[path] = true; return true end
    return false
end
function M.unpin_file(ctx, path)
    if ctx.pinned_files[path] then ctx.pinned_files[path] = nil; return true end
    return false
end
function M.touch_file(ctx, path)
    if not path or not ctx.knowledge_base[path] then return end
    ctx.global_access_counter = ctx.global_access_counter + 1
    ctx.file_access_rank[path] = ctx.global_access_counter
end
-- ============================================================================
-- TOOL OUTPUTS & REQUESTED FILES
-- ============================================================================
function M.add_tool_output(ctx, tool_name, output)
    if not output or output == "" then return end
    local max_len = (ctx.flow_config.compression and ctx.flow_config.compression.max_tool_output_bytes) or 2048
    local truncated = #output > max_len and output:sub(1, max_len) .. "\n...[TRUNCATED]" or output
    table.insert(ctx.recent_tool_outputs, { tool = tool_name, output = truncated })
    local max_outputs = ctx.flow_config.storage.max_recent_tool_outputs or 50
    while #ctx.recent_tool_outputs > max_outputs do
        table.remove(ctx.recent_tool_outputs, 1)
    end
end
function M.track_requested_file(ctx, path)
    if path then ctx.turn_requested_files[path] = true end
end
function M.clear_turn_requested_files(ctx)
    ctx.turn_requested_files = {}
end
-- ============================================================================
-- COMMAND DEDUPLICATION
-- ============================================================================
-- Helper: check if a normalized command matches any exception pattern.
-- Patterns ending with '*' are treated as prefix wildcards.
local function _matches_exception(normalized, exceptions)
    for _, exc in ipairs(exceptions) do
        if exc:sub(-1) == "*" then
            -- Wildcard prefix pattern: strip trailing '*' and check prefix
            local prefix = exc:sub(1, #exc - 1)
            if normalized:sub(1, #prefix) == prefix then
                return true
            end
        else
            -- Exact match
            if normalized == exc then
                return true
            end
        end
    end
    return false
end
function M.is_duplicate_command(ctx, cmd)
    local normalized = (cmd or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then return false end
    local exceptions = ctx.flow_config.command_flow.dedup_exceptions or { "task_complete" }
    -- logger.info(string.format('[DEDUP DEBUG] Normalized command: "%s"', normalized))
    -- Check against exception patterns (exact + wildcard prefix)
    local is_exception = _matches_exception(normalized, exceptions)
    -- logger.info(string.format('[DEDUP DEBUG] _matches_exception result: %s', tostring(is_exception)))
    if is_exception then
        return false
    end
    for _, prev_cmd in ipairs(ctx.executed_commands) do
        -- logger.info(string.format('[DEDUP DEBUG] Comparing against prev_cmd: "%s" (match=%s)', prev_cmd, tostring(prev_cmd == normalized)))
        if prev_cmd == normalized then return true end
    end
    return false
end
function M.add_executed_command(ctx, cmd)
    local normalized = (cmd or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then return end
    -- Do NOT record commands that match exception patterns (they are ephemeral)
    local exceptions = ctx.flow_config.command_flow.dedup_exceptions or { "task_complete" }
    if _matches_exception(normalized, exceptions) then
        return
    end
    table.insert(ctx.executed_commands, normalized)
    if #ctx.executed_commands > 20 then
        table.remove(ctx.executed_commands, 1)
    end
end
-- ============================================================================
-- SEARCH HISTORY
-- ============================================================================
function M.has_searched(ctx, query)
    return ctx.search_history[query] ~= nil
end
local SEARCH_HISTORY_MAX = 100
function M.add_search_result(ctx, query, result)
    if ctx.search_history[query] == nil then
        -- New entry: check if we need to evict
        local count = 0
        for _ in pairs(ctx.search_history) do count = count + 1 end
        if count >= SEARCH_HISTORY_MAX then
            -- Evict oldest entry (first key in iteration order)
            local oldest_key = nil
            for k in pairs(ctx.search_history) do
                oldest_key = k
                break
            end
            if oldest_key then
                ctx.search_history[oldest_key] = nil
            end
        end
    end
    ctx.search_history[query] = result
end
-- ============================================================================
-- THOUGHTS
-- ============================================================================
function M.add_thought(ctx, turn, thought_text)
    ctx.thoughts = ctx.thoughts or {}
    local clean = utils.trim(thought_text)
    if clean == "" then return end
    table.insert(ctx.thoughts, { turn = turn, content = clean })
end
function M.get_thoughts_digest(ctx)
    if not ctx.thoughts or #ctx.thoughts == 0 then return "" end
    local out = {"\n=== AGENT RECENT THOUGHTS ==="}
    for _, th in ipairs(ctx.thoughts) do table.insert(out, th.content) end
    return table.concat(out, "\n")
end
-- ============================================================================
-- HISTORY MANIPULATION
-- ============================================================================
function M.drop_last_message(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    if #history > 0 then table.remove(history); return true end
    return false
end
function M.replace_last_assistant_message(ctx, agent_name, new_content)
    local history = M.get_history(ctx, agent_name)
    for i = #history, 1, -1 do
        if history[i].role == "assistant" then history[i].content = new_content; return true end
    end
    return false
end
function M.should_squash(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    local limits = ctx.flow_config.storage
    if #history > limits.squash_threshold_messages then return true end
    local total_tokens = 0
    for _, msg in ipairs(history) do total_tokens = total_tokens + ctx:estimate_tokens(msg.content) end
    if total_tokens > limits.squash_threshold_tokens then return true end
    return false
end
return M