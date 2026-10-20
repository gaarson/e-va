local utils = require("utils")
local UPDATE_SUMMARY_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "update_summary: Updates the task summary.",
}
local function register(registry)
    registry.register("update_summary", "Replaces the running task summary (visible in system context each turn). Keep it concise: current state + next action.", "||| COMMAND |||\nupdate_summary:We have fixed the login bug. Now working on the dashboard.\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local summary = utils.trim(args)
        if summary == "" then
            return { output = "\n[ERROR]: Summary cannot be empty." }
        end
        ctx:update_summary(summary)
        return { output = "\n[SYSTEM]: Task summary updated successfully." }
    end,
    nil,
    UPDATE_SUMMARY_MANIFEST)
end
return { register = register }