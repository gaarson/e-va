local utils = require("utils")

local function register(registry)
    registry.register("unpin", "Unpins a file from permanent memory", "<cmd>unpin:src/core.h</cmd>", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if ctx:unpin_file(rel_path) then
            return { output = "\n[SYSTEM]: Unpinned '" .. rel_path .. "'." }
        else
            return { output = "\n[ERROR]: '" .. rel_path .. "' was not pinned." }
        end
    end)
end

return { register = register }