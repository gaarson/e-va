local utils = require("utils")
local PIN_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "pin: Pins a loaded file in memory so it is never evicted.",
}
local function register(registry)
    registry.register("pin", "Pins a loaded file in memory so it is never evicted", "||| COMMAND |||\npin:src/core.h\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if not ctx.knowledge_base[rel_path] then
            -- Lazy reload: after snapshot restore, knowledge_base is empty but file_states may have the path
            if ctx.file_states and ctx.file_states[rel_path] then
                local full_path = ctx.config.PROJECT_ROOT .. '/' .. rel_path
                local content, err = utils.read_file_range(full_path)
                if content then
                    ctx:add_file(rel_path, content)
                else
                    return { output = "\n[ERROR]: File '" .. rel_path .. "' was known previously but could not be re-read from disk: " .. tostring(err) }
                end
            else
                return { output = "\n[ERROR]: File '" .. rel_path .. "' is not in memory. Use read_file first." }
            end
        end
        if ctx:pin_file(rel_path) then
            return { output = "\n[SYSTEM]: Pinned '" .. rel_path .. "' to permanent memory block." }
        else
            return { output = "\n[ERROR]: Failed to pin '" .. rel_path .. "'." }
        end
    end, nil, PIN_MANIFEST)
end
return { register = register }
