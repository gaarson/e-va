local utils = require("utils")
local function register(registry)
    registry.register("read_file", "Loads full file into memory", "||| COMMAND |||\nread_file:src/main.c\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if ctx.knowledge_base[rel_path] then
            local full_content = ctx.knowledge_base[rel_path]
            local file_msg = string.format("\n<file_context path=\"%s\" status=\"REQUESTED\">\n%s\n</file_context>", rel_path, full_content)

            -- Вставляем полный контент в последнее сообщение пользователя
            local history = ctx:get_history(agent_name)
            local inserted = false
            for i = #history, 1, -1 do
                if history[i].role == "user" then
                    history[i].content = history[i].content .. "\n\n" .. file_msg
                    inserted = true
                    break
                end
            end
            if not inserted then
                ctx:add_message(agent_name, "user", file_msg)
            end

            ctx.promoted_files = ctx.promoted_files or {}
            ctx.promoted_files[rel_path] = true

            return { output = "\n[SYSTEM]: File '" .. rel_path .. "' has been moved to the active conversation history for your review. Proceed with your next step." }
        else
            local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
            local content, err = utils.read_file_range(full_path)
            if content then
                ctx:add_file(rel_path, content)
                ctx:track_requested_file(rel_path)
                local file_context_xml = ctx:get_file_context({ path = rel_path, is_target = false, is_pinned = false, is_modified = false })
                return { output = "\n[SYSTEM]: Successfully loaded '" .. rel_path .. "' into memory.\n\n" .. file_context_xml .. "\n." }
            else
                return { output = "\n[ERROR]: " .. tostring(err) }
            end
        end
    end)
end
return { register = register }
