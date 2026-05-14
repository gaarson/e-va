local utils = require("utils")

local function register(registry)
    registry.register("explore_tree", "Explore directory structure with depth limit", "<cmd>explore_tree:src/api:2</cmd>", function(args, ctx, agent_name)
        local path, depth = args:match("^(.-):(%d+)$")
        if not path then
            path = utils.trim(args)
            depth = 1
        end

        local tree_view = utils.explore_directory(ctx.config.PROJECT_ROOT, path, depth)
        ctx.file_tree = tree_view
        return { output = string.format("\n[SYSTEM]: Explored directory '%s' (Depth: %s).\n```text\n%s\n```", path, depth, tree_view) }
    end)
end

return { register = register }