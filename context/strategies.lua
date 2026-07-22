-- context/strategies.lua
-- Pruning and injection strategies extracted from context_flow.lua.
local M = {}
local utils = require("utils")
local config = require("context.config")
-- Re-export IMPORTANCE_SCORES from config for backward compatibility
M.IMPORTANCE_SCORES = config.IMPORTANCE_SCORES
-- ============================================================================
-- IMPORTANCE SCORING
-- ============================================================================
local function _score_message(msg, idx, total, importance_scores)
    if not msg then return 0 end
    local role = msg.role or ""
    local content = msg.content or ""
    importance_scores = importance_scores or M.IMPORTANCE_SCORES
    -- First 3 messages are always high priority (task initiation)
    if idx <= 3 then return 100 end
    -- Role-based scoring
    if role == "user" then
        if content:match("^TASK:") or content:match("^QUESTION:") or content:match("%?%s*$") then
            return importance_scores.USER_QUESTION
        end
        if content:match("^\\[OUTPUT\\]") or content:match("^\\[RESULT\\]") or content:match("^\\[SYSTEM") then
            return importance_scores.TOOL_OUTPUT
        end
        return importance_scores.USER_QUESTION
    elseif role == "assistant" then
        if content:match("||| COMMAND |||") then
            return importance_scores.ASSISTANT_REASONING + 10
        end
        if content:match("^\\[SYSTEM MEMORY:") then
            return importance_scores.SQUASHED_MUTATION
        end
        return importance_scores.ASSISTANT_REASONING
    elseif role == "system" then
        return 60
    end
    return 20
end
-- ============================================================================
-- PRUNE STRATEGIES
-- ============================================================================
M.PRUNE_STRATEGIES = {
    fifo = function(history, limits)
        while #history > limits.max_history_messages do table.remove(history, 1) end
    end,
    importance_weighted = function(history, limits, estimate_fn, importance_scores)
        local max_msgs = limits.max_history_messages or 200
        while #history > max_msgs do
            local min_score = math.huge
            local min_idx = nil
            for i = 4, #history do
                local score = _score_message(history[i], i, #history, importance_scores)
                if score < min_score then
                    min_score = score
                    min_idx = i
                elseif score == min_score and min_idx then
                    if i < min_idx then
                        min_idx = i
                    end
                end
            end
            if min_idx and min_idx >= 4 then
                table.remove(history, min_idx)
            else
                break
            end
        end
    end,
    fifo_assistant_first = function(history, limits)
        while #history > limits.max_history_messages do
            local idx = 1
            if history[idx] and history[idx].role == "user" then
                table.remove(history, idx)
            else
                table.remove(history, 1)
            end
        end
    end,
    squash_large_patches = function(history, limits, estimate_fn)
        local total = 0
        for _, m in ipairs(history) do total = total + estimate_fn(m.content) end
        if total > limits.max_history_tokens then
            for i = 1, #history - 5 do
                if history[i] and history[i].role == "assistant" then
                    local c = history[i].content or ""
                    if c:match("||| COMMAND |||\npatch:") or c:match("||| COMMAND |||\ncreate_file:") then
                        history[i].content = "[SYSTEM MEMORY: Previous code mutation squashed to save context.]"
                        total = total - estimate_fn(c) + estimate_fn(history[i].content)
                        if total <= limits.max_history_tokens then break end
                    end
                end
            end
        end
    end,
    squash_large_outputs = function(history, limits, estimate_fn)
        local total = 0
        for _, m in ipairs(history) do total = total + estimate_fn(m.content) end
        if total > limits.max_history_tokens then
            for i = 1, #history - 5 do
                local msg = history[i]
                if not msg then break end
                local c = msg.content or ""
                local original_len = #c
                -- Squash large shell outputs (>2KB)
                if c:match("^\\[SHELL OUTPUT\\]") or c:match("^\\[SHELL STDOUT") then
                    if original_len > 2048 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Shell output truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                -- Squash large search results (>1KB)
                elseif c:match("^\\[SEARCH RESULTS\\]") or c:match("^=== SEARCH DIGEST ===") then
                    if original_len > 1024 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Search results truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                -- Squash large tool outputs (>2KB)
                elseif c:match("^\\[OUTPUT\\]") or c:match("^\\[RESULT\\]") then
                    if original_len > 2048 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Tool output truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                end
                if total <= limits.max_history_tokens then break end
            end
        end
    end
}
-- ============================================================================
-- INJECTION STRATEGIES
-- ============================================================================
M.INJECTION_STRATEGIES = {
    separate_message = function(messages, recency, digest)
        local block = recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        table.insert(messages, { role = "user", content = block })
    end,
    append_to_last_user = function(messages, recency, digest)
        local block = recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        if block == "" then return end
        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                local content = messages[i].content
                -- Remove previous dynamic blocks to avoid accumulation
                content = content:gsub("<execution_plan>([%s\S]*)</execution_plan>", "")
                content = content:gsub("<last_actions>([%s\S]*)</last_actions>", "")
                content = content:gsub("<file_context[^>]->([%s\S]*)</file_context>", "")
                content = content:gsub("\n\n+", "\n\n")
                content = utils.trim(content)
                messages[i].content = (content ~= "" and content .. "\n\n" or "") .. block
                break
            end
        end
    end,
    hybrid_insert = function(messages, recency, digest)
        local block = recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        if block == "" then return end
        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                table.insert(messages, i, { role = "system", content = "[DYNAMIC CONTEXT]\n" .. block })
                break
            end
        end
    end,
    system_block = function(messages, recency, digest)
        local block = "<system_context>\n" .. recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        block = block .. "\n</system_context>"
        table.insert(messages, 1, { role = "system", content = block })
    end
}
return M