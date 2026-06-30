local utils = require("utils")
local function register(registry)
    registry.register("search_and_read", "Searches for files matching a pattern and reads them into memory. Useful for reading all files in a directory or matching a glob pattern.", "||| COMMAND |||\nsearch_and_read:src/*.c\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local pattern = utils.trim(args)
        if pattern == "" then
            return { output = "\n[ERROR]: No pattern specified. Use ||| COMMAND |||\nsearch_and_read:src/*.c\n||| END_COMMAND |||" }
        end
        
        local safe_pattern = utils.shell_quote(pattern)
        local safe_root = utils.shell_quote(ctx.config.PROJECT_ROOT)
        local cmd = string.format("find %s -type f -name '%s' 2>/dev/null | head -n 20", safe_root, safe_pattern)
        
        local f = io.popen(cmd)
        local files = f:read("*a") or ""
        f:close()
        
        if files == "" then
            return { output = string.format("\n[SYSTEM]: No files found matching pattern '%s'", pattern) }
        end
        
        local results = {}
        local loaded = 0
        local errors = 0
        
        for path in files:gmatch("[^\r\n]+") do
            if path == "" then break end
            local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            if ctx.knowledge_base[rel_path] then
                table.insert(results, string.format("- %s: ALREADY in memory", rel_path))
            else
                local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
                local content, err = utils.read_file_range(full_path)
                if content then
                    ctx:add_file(rel_path, content)
                    table.insert(results, string.format("- %s: Loaded successfully", rel_path))
                    loaded = loaded + 1
                else
                    table.insert(results, string.format("- %s: ERROR - %s", rel_path, tostring(err)))
                    errors = errors + 1
                end
            end
        end
        
        local output = string.format("\n[SYSTEM]: Search and read complete. Loaded: %d, Errors: %d\n%s", loaded, errors, table.concat(results, "\n"))
        return { output = output }
    end)
end
return { register = register }
