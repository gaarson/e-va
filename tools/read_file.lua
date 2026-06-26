local utils = require("utils")
local function register(registry)
    registry.register("read_file", "Loads full file into memory", ">>> COMMAND >>>\nread_file:src/main.c\n>>> END_COMMAND >>>", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if ctx.knowledge_base[rel_path] then
            return { output = "\n[SYSTEM]: File '" .. rel_path .. "' is ALREADY in memory. Scroll up and look at the <file_context path=\""..rel_path.."\> XML block in your SYSTEM PROMPT to read its contents. DO NOT call read_file on this path again. Proceed with your next step." }
        else
            local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
            local content, err = utils.read_file_range(full_path)
            if content then
                ctx:add_file(rel_path, content)
                ctx:track_requested_file(rel_path)
                local file_context_xml = ctx:get_file_context({ path = rel_path, is_target = false, is_pinned = false, is_modified = false })
                return { output = "\n[SYSTEM]: Successfully loaded '" .. rel_path .. "' into memory.\n\n" .. file_context_xml .. "\n\nProceed with your next step." }
            else
                return { output = "\n[ERROR]: " .. tostring(err) }
            end
        end
    end)
end
return { register = register }
