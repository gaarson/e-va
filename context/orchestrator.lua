-- context/orchestrator.lua
-- Orchestrator: optimize_context only.
-- All other utility methods were moved to context/builder.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local history = require("context.history")
local state_mod = require("context.state")

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
end

return M
