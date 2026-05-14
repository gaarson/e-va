local utils = require("utils")

local function register(registry)
    registry.register("ask_user", "Pause execution and ask the human user a question", "<cmd>ask_user:Is this logic correct?</cmd>", function(args, ctx, agent_name)
        io.write(string.format("\n\27[33m[AGENT '%s' ASKS]:\27[0m %s\n", agent_name, args))
        io.write("\27[36m>>> YOUR REPLY (or press Enter to skip):\27[0m ")
        local ans = io.read("*l")
        if not ans or utils.trim(ans) == "" then
            return { output = "\n[USER REPLY]: (No response provided by user. Proceed with your best judgment.)" }
        end
        return { output = "\n[USER REPLY]: " .. ans }
    end)
end

return { register = register }