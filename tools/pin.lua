local utils = require("utils")

local function register(registry)
    registry.register("pin", "Pins a loaded file in memory so it is never evicted", ">>> COMMAND >>>\npin:src/core.h\n>>> END_COMMAND >>>", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)

        if not ctx.knowledge_base[rel_path] then
            return { output = "\n[ERROR]: File '" .. rel_path .. "' is not in memory. Use >>> COMMAND >>>\nread_file:" .. rel_path .. "\n>>> END_COMMAND >>> first." }
        end

        if ctx:pin_file(rel_path) then
            return { output = "\n[SYSTEM]: Pinned '" .. rel_path .. "' to permanent memory block." }
        else
            return { output = "\n[ERROR]: Failed to pin '" .. rel_path .. "'." }
        end
    end)
end

return { register = register }
