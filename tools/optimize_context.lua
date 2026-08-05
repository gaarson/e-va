local utils = require("utils")
local json = require("JSON")
local optimizer = require("optimizer")
local orchestrator = require("context.orchestrator")

local OPTIMIZE_CONTEXT_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "optimize_context: Optimizes context by removing files, summarizing history, pinning files.",
}

local function register(registry)
    registry.register("optimize_context",
        "Optimizes the current context by removing unnecessary files, updating the task summary, pinning/unpinning files, or summarizing conversation history. Use this when the context is getting too large or when you want to ensure critical information is preserved. Supports: remove_files, pin_files, unpin_files, update_summary, summarize_history (with agent_name and keep_count).",
        "||| COMMAND |||\noptimize_context:{\"remove_files\": [\"path/to/file1.txt\"], \"pin_files\": [\"path/to/core.h\"], \"update_summary\": \"New summary text\", \"summarize_history\": {\"agent_name\": \"architect\", \"keep_count\": 10}}\n||| END_COMMAND |||",
        function(args, ctx, agent_name)
            -- ALWAYS parse explicit JSON instructions first
            local instructions = {}
            local json_match = utils.trim(args:gsub("`+", ""))
            
            if json_match ~= "" then
                local ok, parsed = pcall(function() return json:decode(json_match) end)
                if ok and type(parsed) == "table" then
                    instructions = parsed
                else
                    return { output = "\n[ERROR]: Invalid JSON format for optimize_context. Use: {\"remove_files\": [...], \"pin_files\": [...], \"update_summary\": \"...\"}" }
                end
            end
            -- Delegate explicit instructions to orchestrator (handles remove_files, pin_files, unpin_files, update_summary, summarize_history)
            if next(instructions) then
                orchestrator.optimize_context(ctx, instructions)
            end
            -- OPTIONALLY run LLM-driven optimization if OPTIMIZER_AGENT is configured
            if ctx.config and ctx.config.OPTIMIZER_AGENT then
                optimizer.analyze_and_optimize(ctx, ctx.config)
            end
            return { output = "\n[SYSTEM]: Context optimized." }
        end,
        OPTIMIZE_CONTEXT_MANIFEST)
end

return { register = register }