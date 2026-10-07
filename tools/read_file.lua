local utils = require("utils")
local READ_FILE_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output_str, ctx, payload, intent, file_path)
        local extra = ""
        if file_path and file_path ~= "" then
            local normalized = file_path
            if not file_path:match("^/") then
                normalized = utils.normalize_path(ctx.config.PROJECT_ROOT, file_path)
            end
            local content = ctx.knowledge_base[normalized]
            if content then
                extra = string.format("\n\n<file_content_after_read path=\"%s\">\n%s\n</file_content_after_read>", normalized, content)
            end
        end
        return output_str .. extra
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "read_file: Loads full file content into context for analysis.",
}
local function register(registry)
    registry.register("read_file", "Loads full file into memory", "||| COMMAND |||\nread_file:src/main.c\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if ctx.knowledge_base[rel_path] then
            -- Cache hit: re-inject content so LLM actually sees it (may have been pruned from history).
            ctx:touch_file(rel_path)
            ctx:track_requested_file(rel_path)
            local kb_content = ctx.knowledge_base[rel_path]
            local file_size = #kb_content
            local file_context_xml = ctx:get_file_context({ path = rel_path, is_target = false, is_pinned = false, is_modified = false })
            local hint = ""
            if file_size > 2000 then
                hint = string.format("\nTip: This file is %d bytes. Use `read_chunk:%s:start-end` to inspect specific sections if needed.", file_size, rel_path)
            end
            return { output = string.format("\n[SYSTEM]: File '%s' reloaded into visible context (%d bytes).%s\n%s", rel_path, file_size, hint, file_context_xml) }
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
    end,
    nil,
    READ_FILE_MANIFEST)
end
return { register = register }
