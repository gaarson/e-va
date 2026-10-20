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
        "Optimizes context: removes files from KB, pins/unpins files, updates task summary, or summarizes history. Accepts JSON instructions. Optionally runs LLM-driven optimizer if OPTIMIZER_AGENT is configured.",
        "||| COMMAND |||\noptimize_context:{\"remove_files\": [\"src/old.lua\"], \"pin_files\": [\"src/core.h\"], \"update_summary\": \"Fixed login bug\", \"summarize_history\": {\"agent_name\": \"architect\", \"keep_count\": 10}}\n||| END_COMMAND |||\n\nJSON FIELDS (all optional, combine as needed):\n- remove_files: [\"path1\", \"path2\"] — evict from knowledge_base.\n- pin_files: [\"path1\"] — mark as permanent (never evicted).\n- unpin_files: [\"path1\"] — remove pin status.\n- update_summary: \"text\" — replace task summary.\n- summarize_history: {\"agent_name\": \"<name>\", \"keep_count\": <N>} — compress older turns.\n\nBEHAVIOR:\n- Invalid JSON → error message with format hint.\n- Empty args (no JSON) → returns success with no-op.\n- If config.OPTIMIZER_AGENT is set: additionally runs LLM-driven context analysis.\n- Delegates to context.orchestrator for actual operations.",
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
        nil, OPTIMIZE_CONTEXT_MANIFEST)
end

return { register = register }