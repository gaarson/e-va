local utils = require("utils")
local function register(registry)
    registry.register("read_files", "Reads multiple files into memory at once. Use this instead of multiple read_file commands to save turns.", "$$$ COMMAND $$$\nread_files:src/main.c,src/utils.h,src/config.lua\n$$$ END_COMMAND $$$", function(args, ctx, agent_name)
        local paths = {}
        for path in args:gmatch("([^,]+)") do
            table.insert(paths, utils.trim(path))
        end
        
        if #paths == 0 then
            return { output = "\n[ERROR]: No files specified. Use $$$ COMMAND $$$\nread_files:file1,file2,file3\n$$$ END_COMMAND $$$" }
        end
        
        local results = {}
        local loaded = 0
        local errors = 0
        
        for _, path in ipairs(paths) do
            local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            if ctx.knowledge_base[rel_path] then
                table.insert(results, string.format("- %s: ALREADY in memory", rel_path))
            else
                local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
                local content, err = utils.read_file_range(full_path)
                if content then
                    ctx:add_file(rel_path, content)
                    ctx:track_requested_file(rel_path)
                    table.insert(results, string.format("- %s: Loaded successfully", rel_path))
                    loaded = loaded + 1
                else
                    table.insert(results, string.format("- %s: ERROR - %s", rel_path, tostring(err)))
                    errors = errors + 1
                end
            end
        end
        
        local output = string.format("\n[SYSTEM]: Batch file read complete. Loaded: %d, Errors: %d\n%s", loaded, errors, table.concat(results, "\n"))
        return { output = output }
    end)
end
return { register = register }
