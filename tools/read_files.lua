local utils = require("utils")

local READ_FILES_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        if not payload or utils.trim(payload) == "" then
            return false, "read_files payload is empty."
        end
        -- Must contain at least one path (comma-separated)
        local count = 0
        for _ in payload:gmatch("[^,]+") do count = count + 1 end
        if count == 0 then
            return false, "read_files: no valid file paths found."
        end
        return true, nil
    end,
    enrich_result = function(output_str)
        return output_str
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "read_files: Batch-load multiple files into context. Use comma-separated paths.",
}

local function register(registry)
    registry.register("read_files",
        "Reads multiple files into memory at once (comma-separated). Saves turns vs multiple read_file calls.",
        "||| COMMAND |||\nread_files:src/main.c,src/utils.h,src/config.lua\n||| END_COMMAND |||",
        function(args, ctx, agent_name)
            local paths = {}
            for path in args:gmatch("([^,]+)") do
                table.insert(paths, utils.trim(path))
            end

            if #paths == 0 then
                return { output = "\n[ERROR]: No files specified. Format: read_files:file1,file2,file3" }
            end

            local results = {}
            local loaded = 0
            local errors = 0
            local already = 0

            for _, path in ipairs(paths) do
                if path == "" then goto continue end
                local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
                if ctx.knowledge_base[rel_path] then
                    table.insert(results, string.format("- %s: ALREADY in memory", rel_path))
                    already = already + 1
                else
                    local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
                    local content, err = utils.read_file_range(full_path)
                    if content then
                        ctx:add_file(rel_path, content)
                        ctx:track_requested_file(rel_path)
                        table.insert(results, string.format("- %s: Loaded (%d bytes)", rel_path, #content))
                        loaded = loaded + 1
                    else
                        table.insert(results, string.format("- %s: ERROR - %s", rel_path, tostring(err)))
                        errors = errors + 1
                    end
                end
                ::continue::
            end

            local output = string.format("\n[SYSTEM]: Batch read complete. Loaded: %d, Already cached: %d, Errors: %d\n%s", loaded, already, errors, table.concat(results, "\n"))
            return { output = output }
        end,
        nil, READ_FILES_MANIFEST)
end

return { register = register }