local utils = require("utils")

local UNPIN_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "unpin: Unpins a file from permanent memory.",
}

local function register(registry)
    registry.register("unpin", "Unpins a file from permanent memory", "||| COMMAND |||\nunpin:src/core.h\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if ctx:unpin_file(rel_path) then
            return { output = "\n[SYSTEM]: Unpinned '" .. rel_path .. "'." }
        else
            return { output = "\n[ERROR]: '" .. rel_path .. "' was not pinned." }
        end
    end, nil, UNPIN_MANIFEST)
end

return { register = register }