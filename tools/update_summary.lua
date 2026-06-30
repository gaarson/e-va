-- tools/update_summary.lua
local utils = require("utils")
local function register(registry)
    registry.register("update_summary", "Updates the high-level summary of the current task and its status. Use this to keep the context fresh for future turns.", "||| COMMAND |||\nupdate_summary:We have fixed the login bug. Now working on the dashboard.\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local summary = utils.trim(args)
        if summary == "" then
            return { output = "\n[ERROR]: Summary cannot be empty." }
        end
        ctx:update_summary(summary)
        return { output = "\n[SYSTEM]: Task summary updated successfully." }
    end)
end
return { register = register }

