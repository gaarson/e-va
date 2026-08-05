local utils = require("utils")

local EXPLORE_TREE_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "explore_tree: Explore directory structure with depth limit.",
}

local function register(registry)
    registry.register("explore_tree", "Explore directory structure with depth limit", "||| COMMAND |||\nexplore_tree:src/api:2\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local path, depth = args:match("^(.-):(%d+)$")
        if not path then
            path = utils.trim(args)
            depth = 1
        end

        local tree_view = utils.explore_directory(ctx.config.PROJECT_ROOT, path, depth)
        ctx.file_tree = tree_view
        return { output = string.format("\n[SYSTEM]: Explored directory '%s' (Depth: %s).\n```text\n%s\n```", path, depth, tree_view) }
    end, nil, EXPLORE_TREE_MANIFEST)
end

return { register = register }