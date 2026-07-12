-- context/history.lua
-- History and knowledge-base management extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local utils = require("utils")
local compressor = require("context_compressor")
local logger = require("logger")
local config_mod = require("context.config")
local strategies_mod = require("context.strategies")
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
function M.prune_history(ctx, agent_name)
    local history = M.get_history(ctx, agent_name)
    local limits = ctx.flow_config.storage
    local agent_cfg = ctx.config.AGENTS[agent_name]
    local estimate = function(t) return ctx:estimate_tokens(t, agent_cfg) end
    -- STEP 1: Apply compression BEFORE pruning
    if ctx.flow_config.compression and ctx.flow_config.compression.enabled then
        M.compress_history(ctx, agent_name)
    end
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
            local squashed = original:gsub("||| COMMAND |||\n(patch|create_file):([^%s\n]+)%s*\n.-||| END_COMMAND |||",
                function(_, file_path) return string.format("\n[SYSTEM MEMORY: %s applied to '%s'.]\n",
                    (file_path == "patch" and "Patch" or "File"), file_path or "unknown") end)
            squashed = utils.trim(squashed:gsub("\n\n+", "\n\n"))
            if original ~= squashed then
                history[i].content = squashed
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
    local max_len = 10000000
    local truncated = #output > max_len and output:sub(1, max_len) .. "\n...[TRUNCATED]" or output
    table.insert(ctx.recent_tool_outputs, { tool = tool_name, output = truncated })
    if #ctx.recent_tool_outputs > ctx.flow_config.storage.max_recent_tool_outputs then
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
function M.is_duplicate_command(ctx, cmd)
    local normalized = (cmd or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then return false end
    local exceptions = ctx.flow_config.command_flow.dedup_exceptions or { "task_complete" }
    for _, exc in ipairs(exceptions) do
        if normalized == exc then return false end
    end
    for _, prev_cmd in ipairs(ctx.executed_commands) do
        if prev_cmd == normalized then return true end
    end
    return false
end
function M.add_executed_command(ctx, cmd)
    local normalized = (cmd or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then return end
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
function M.add_search_result(ctx, query, result)
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