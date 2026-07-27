-- context/orchestrator.lua
-- Orchestrator: optimize_context only.
-- All other utility methods were moved to context/builder.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local history = require("context.history")
local state_mod = require("context.state")
local summarization = require("optimizer.summarization")
local comp_helpers = require("context_compressor.helpers")

-- ============================================================================
-- OPTIMIZE CONTEXT
-- ============================================================================
function M.optimize_context(ctx, instructions)
    if type(instructions) ~= "table" then return end
    if instructions.remove_file then
        ctx.knowledge_base[instructions.remove_file] = nil
        ctx.file_states[instructions.remove_file] = nil
        ctx.file_access_rank[instructions.remove_file] = nil
        state_mod.add_action(ctx, "CONTEXT_OPTIMIZATION", "Removed file from memory: " .. instructions.remove_file)
    end
    if instructions.pin_file then history.pin_file(ctx, instructions.pin_file) end
    if instructions.unpin_file then history.unpin_file(ctx, instructions.unpin_file) end
    if instructions.update_summary then state_mod.update_summary(ctx, instructions.update_summary) end
    if type(instructions.remove_files) == "table" then
        for _, path in ipairs(instructions.remove_files) do
            ctx.knowledge_base[path] = nil
            ctx.file_states[path] = nil
            ctx.file_access_rank[path] = nil
            state_mod.add_action(ctx, "CONTEXT_OPTIMIZATION", "Removed file from memory: " .. path)
        end
    end
    if type(instructions.pin_files) == "table" then
        for _, path in ipairs(instructions.pin_files) do history.pin_file(ctx, path) end
    end
    if type(instructions.unpin_files) == "table" then
        for _, path in ipairs(instructions.unpin_files) do history.unpin_file(ctx, path) end
    end
    -- NEW: summarize_history instruction
    if instructions.summarize_history and type(instructions.summarize_history) == "table" then
        local sh = instructions.summarize_history
        local agent_name = sh.agent_name or sh[1]
        local keep_count = sh.keep_count or sh[2] or 10
        if not agent_name then return end
        local msgs = history.get_history(ctx, agent_name)
        if #msgs <= keep_count then return end
        -- Identify messages to remove (oldest beyond keep_count)
        local removed_msgs = {}
        for i = 1, #msgs - keep_count do
            table.insert(removed_msgs, msgs[i])
        end
        -- Find and preserve task anchor
        local task_anchor = nil
        for _, msg in ipairs(removed_msgs) do
            if msg.role == "user" and msg.content and msg.content:match("^TASK:") then
                task_anchor = msg
                break
            end
        end
        -- Filter out task anchor from removed messages
        local msgs_to_summarize = {}
        for _, msg in ipairs(removed_msgs) do
            if msg ~= task_anchor then
                table.insert(msgs_to_summarize, msg)
            end
        end
        -- Attempt LLM summarization
        local summary_text = ""
        if #msgs_to_summarize > 0 then
            local cfg = ctx.config or {}
            local ok, result = pcall(summarization.summarize_conversation_segment, msgs_to_summarize, nil, cfg)
            if ok and result and #result > 0 then
                summary_text = result
            else
                -- Fallback: use context_compressor.helpers
                local fallback_parts = {}
                for _, msg in ipairs(msgs_to_summarize) do
                    local part = comp_helpers._summarize_message(msg, nil)
                    if part and #part > 0 then
                        table.insert(fallback_parts, part)
                    end
                end
                if #fallback_parts > 0 then
                    summary_text = table.concat(fallback_parts, ". ")
                end
            end
        end
        -- Build new history
        local new_hist = {}
        if task_anchor then
            table.insert(new_hist, task_anchor)
        end
        if #summary_text > 0 then
            table.insert(new_hist, {
                role = "system",
                content = string.format("[CONTEXT SUMMARY: Summarized from %d removed messages]\n%s", #removed_msgs, summary_text)
            })
        end
        for i = #msgs - keep_count + 1, #msgs do
            table.insert(new_hist, msgs[i])
        end
        ctx.history[agent_name] = new_hist
        state_mod.add_action(ctx, "CONTEXT_OPTIMIZATION", "Summarized history for agent: " .. agent_name .. " (kept " .. keep_count .. " most recent)")
    end
end
return M