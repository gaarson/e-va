local utils = require("utils")

local OUTLINE_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "outline: Generates an AST-like outline of a file (functions, classes, structs).",
}

local function register(registry)
    registry.register("outline", "Generates an AST-like outline of a file (functions, classes, structs)", "||| COMMAND |||\noutline:src/main.c\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path

        local f = io.open(full_path, "r")
        if not f then return { output = "\n[ERROR]: File not found: " .. rel_path } end
        f:close()

        local safe_path = utils.shell_quote(full_path)
        local rg_regex = "'^\\s*(local\\s+)?(function|class|struct|interface|type)\\s+|^\\s*[a-zA-Z_]\\w*\\s+\\*?[a-zA-Z_]\\w*\\s*\\([^;]*\\)\\s*\\{?' "
        local cmd = string.format("rg -n -e %s --color never %s | head -n 100", rg_regex, safe_path)

        local p = io.popen(cmd)
        local res = p:read("*a") or ""
        p:close()

        if #res == 0 then
            return { output = "\n[SYSTEM]: Outline for " .. rel_path .. " is empty or no valid signatures found." }
        end

        return { output = string.format("\n[SYSTEM OUTLINE FOR %s]:\n```\n%s\n```", rel_path, utils.trim(res)) }
    end,
    nil,
    OUTLINE_MANIFEST)
end

return { register = register }