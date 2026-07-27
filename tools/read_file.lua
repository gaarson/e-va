local utils = require("utils")
local function register(registry)
    registry.register("read_file", "Loads full file into memory", "||| COMMAND |||\nread_file:src/main.c\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if ctx.knowledge_base[rel_path] then
            -- File already in knowledge_base (cache hit): do NOT re-embed full content.
            -- Just confirm it's available and suggest read_chunk for large files.
            local kb_content = ctx.knowledge_base[rel_path]
            local file_size = #kb_content
            local hint = ""
            if file_size > 2000 then
                hint = string.format("\nTip: This file is %d bytes. Use `read_chunk:%s:start-end` to inspect specific sections if needed.", file_size, rel_path)
            end
            return { output = string.format("\n[SYSTEM]: File '%s' is already loaded in memory (%d bytes). You can reference it directly.%s", rel_path, file_size, hint) }
        else
            -- First read: load from disk, add to knowledge_base, return file_context XML.
            local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
            local content, err = utils.read_file_range(full_path)
            if content then
                ctx:add_file(rel_path, content)
                ctx:track_requested_file(rel_path)
                local file_context_xml = ctx:get_file_context({ path = rel_path, is_target = false, is_pinned = false, is_modified = false })
                local file_size = #content
                local hint = ""
                if file_size > 2000 then
                    hint = string.format("\nTip: This file is %d bytes. Use `read_chunk:%s:start-end` to inspect specific sections if needed.", file_size, rel_path)
                end
                return { output = "\n[SYSTEM]: Successfully loaded '" .. rel_path .. "' into memory.\n\n" .. file_context_xml .. hint .. "\n." }
            else
                return { output = "\n[ERROR]: " .. tostring(err) }
            end
        end
    end)
end
return { register = register }