local utils = require("utils")

local function register(registry)
    registry.register("pin", "Pins a loaded file in memory so it is never evicted", "<cmd>pin:src/core.h</cmd>", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)

        if not ctx.knowledge_base[rel_path] then
            return { output = "\n[ERROR]: File '" .. rel_path .. "' is not in memory. Use <cmd>read_file:" .. rel_path .. "</cmd> first." }
        end

        if ctx:pin_file(rel_path) then
            return { output = "\n[SYSTEM]: Pinned '" .. rel_path .. "' to permanent memory block." }
        else
            return { output = "\n[ERROR]: Failed to pin '" .. rel_path .. "'." }
        end
    end)
end

return { register = register }