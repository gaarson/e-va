local utils = require("utils")

local function register(registry)
    registry.register("read_chunk", "Reads specific lines from a file", "<cmd>read_chunk:src/main.c:10-25</cmd>", function(args, ctx, agent_name)
        local path, start_l, end_l = args:match("^(.-):(%d+)%-(%d+)$")
        if not path then path, start_l, end_l = args:match("^path:(.-):(%d+)%-(%d+)$") end

        if path then
            local rel = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            local full = ctx.config.PROJECT_ROOT .. "/" .. rel
            local content, total = utils.read_file_numbered(full, tonumber(start_l), tonumber(end_l))
            if content then
                return { output = string.format("\n[SYSTEM] Chunk of '%s' (Lines %s-%s):\n```\n%s\n```", rel, start_l, end_l, content) }
            else
                return { output = "[ERROR] Could not read chunk: " .. rel }
            end
        else
            return { output = "[ERROR] Usage: read_chunk:filename:start-end" }
        end
    end)
end

return { register = register }