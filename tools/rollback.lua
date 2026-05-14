local utils = require("utils")

local function register(registry)
    registry.register("rollback", "Restores file from its .bak version", "<cmd>rollback:src/main.c</cmd>", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
        local ok, err = utils.restore_backup(full_path)
        if ok then
            local content = utils.read_file_range(full_path)
            ctx:add_file(rel_path, content)
            return { output = "\n[SYSTEM]: Rollback successful for " .. rel_path }
        else
            return { output = "\n[ERROR]: Rollback failed - " .. tostring(err) }
        end
    end)
end

return { register = register }