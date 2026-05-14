local utils = require("utils")

local function register(registry)
    registry.register("cleanup_baks", "Deletes all .bak files", "<cmd>cleanup_baks</cmd>", function(args, ctx, agent_name)
        local ok = utils.cleanup_backups(ctx.config.PROJECT_ROOT)
        if ok then return { output = "\n[SYSTEM]: All .bak files removed." }
        else return { output = "\n[ERROR]: Failed to clean up .bak files." } end
    end)
end

return { register = register }