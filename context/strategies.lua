-- context/strategies.lua
-- Pruning and injection strategies extracted from context_flow.lua.
local M = {}
local utils = require("utils")
local config = require("context.config")
local registry = require("tool_registry")
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
    -- TASK: messages are ALWAYS high priority, regardless of position
    if role == "user" and content:match("^TASK:") then return 100 end
    -- First 3 messages are always high priority (task initiation)
    if idx <= 3 then return 100 end
    -- Role-based scoring
    if role == "user" then
        if content:match("^TASK:") or content:match("^QUESTION:") or content:match("%?%s*$") then
            return importance_scores.USER_QUESTION
        end
        if content:match("^%[OUTPUT%]") or content:match("^%[RESULT%]") or content:match("^%[SYSTEM") then
            return importance_scores.TOOL_OUTPUT
        end
        return importance_scores.USER_QUESTION
    elseif role == "assistant" then
        if content:match("||| COMMAND |||") then
            return importance_scores.ASSISTANT_REASONING + 10
        end
        if content:match("^%[SYSTEM MEMORY:") then
            return importance_scores.SQUASHED_MUTATION
        end
        return importance_scores.ASSISTANT_REASONING
    elseif role == "system" then
        -- System memory annotations are low priority (squashed mutations)
        if content:match("^<system-memory>") then
            return importance_scores.SQUASHED_MUTATION
        end
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
                    -- Dynamic detection: check if any mutation tool commands exist
                    local has_mutation = false
                    for tool_name in c:gmatch("||| COMMAND |||\n([%w_]+):") do
                        local tool = registry.tools[tool_name]
                        if tool and tool.manifest and tool.manifest.is_mutation then
                            has_mutation = true
                            break
                        end
                    end
                    if has_mutation then
                        -- Strip command blocks from assistant message, preserving reasoning
                        local squashed = c
                        local mutation_files = {}  -- { tool = "patch", file = "src/main.c" }
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
                        squashed = squashed:gsub("\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
                        if squashed ~= "" then
                            history[i].content = squashed
                        else
                            history[i].content = "[SYSTEM: Code mutation executed.]"
                        end
                        -- Build system memory annotation
                        local mem_parts = {}
                        for _, mf in ipairs(mutation_files) do
                            local action = mf.tool == "patch" and "Patch applied to" or "Mutation applied to"
                            table.insert(mem_parts, string.format("%s '%s' (via %s).", action, mf.file, mf.tool))
                        end
                        local mem_content = "<system-memory>" .. table.concat(mem_parts, " ") .. "</system-memory>"
                        table.insert(history, i + 1, { role = "system", content = mem_content })
                        total = total - estimate_fn(c) + estimate_fn(history[i].content) + estimate_fn(mem_content)
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
                if c:match("^%[SHELL OUTPUT%]") or c:match("^%[SHELL STDOUT") then
                    if original_len > 2048 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Shell output truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                -- Squash large search results (>1KB)
                elseif c:match("^%[SEARCH RESULTS%]") or c:match("^=== SEARCH DIGEST ===") then
                    if original_len > 1024 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Search results truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                -- Squash large tool outputs (>2KB)
                elseif c:match("^%[OUTPUT%]") or c:match("^%[RESULT%]") then
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
                -- STABLE_ANCHOR: Check if <dynamic_context> tag already exists
                if content:match("<dynamic_context>") then
                    -- Replace ONLY the content between <dynamic_context> and </dynamic_context>
                    content = content:gsub("<dynamic_context>.-</dynamic_context>",
                        "<dynamic_context>\n" .. block .. "\n</dynamic_context>")
                    messages[i].content = content
                else
                    -- Remove previous raw dynamic blocks to avoid accumulation, then wrap in anchor
                    content = content:gsub("<execution_plan>([%s\S]*)</execution_plan>", "")
                    content = content:gsub("<last_actions>([%s\S]*)</last_actions>", "")
                    content = content:gsub("<file_context[^>]->([%s\S]*)</file_context>", "")
                    content = content:gsub("\n\n+", "\n\n")
                    content = utils.trim(content)
                    messages[i].content = (content ~= "" and content .. "\n\n" or "") ..
                        "<dynamic_context>\n" .. block .. "\n</dynamic_context>"
                end
                break
            end
        end
    end,
    stable_append = function(messages, recency, digest)
        -- Appends dynamic content as a SEPARATE user message at the end.
        -- This is the most cache-friendly strategy because it leaves all
        -- prior messages completely untouched, preserving their KV-cache entries.
        local block = recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        if block == "" then return end
        -- Remove any previous dynamic_context message to avoid accumulation
        for i = #messages, 1, -1 do
            if messages[i].role == "user" and messages[i].content:match("^<dynamic_context>") then
                table.remove(messages, i)
                break
            end
        end
        table.insert(messages, { role = "user", content = "<dynamic_context>\n" .. block .. "\n</dynamic_context>" })
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