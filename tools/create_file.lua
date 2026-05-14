local utils = require("utils")
local os = require("os")

local function register(registry)
    registry.register("create_file", "Creates or overwrites a file with new content", "<cmd>create_file:src/new.c\n#include <stdio.h>\nint main() { return 0; }\n</cmd>", function(args, ctx, agent_name)
        local path, new_code = args:match("^([^%s]+)%s*\n(.*)")
        if not path then
            return { output = "\n[ERROR]: Invalid create_file syntax. Use <cmd>create_file:path/to/file\n[code]</cmd>" }
        end

        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path

        if utils.read_file_range(full_path) then
            if ctx.config.CREATE_BACKUPS ~= false then
                utils.copy_file(full_path, full_path .. ".bak")
            end
        end

        local dir_path = full_path:match("^(.*)/[^/]+$")
        if dir_path and dir_path ~= "" then
            os.execute("mkdir -p '" .. dir_path .. "' 2>/dev/null")
        end

        local ok, err = utils.write_file(full_path, new_code or "")
        if ok then
            ctx:add_file(rel_path, new_code or "")
            ctx.file_states[rel_path] = "RECENTLY_MODIFIED"
            ctx:squash_last_mutation(agent_name)
            return { output = string.format("\n[SUCCESS]: Created/Overwritten file %s.", rel_path), signal = "MUTATION_SUCCESS" }
        else
            return { output = "\n[ERROR]: " .. tostring(err) }
        end
    end)
end

return { register = register }
