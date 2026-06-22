local utils = require("utils")
local json = require("JSON")

local function register(registry)
    registry.register("optimize_context", 
        "Optimizes the current context by removing unnecessary files, updating the task summary, or pinning critical files. Use this when the context is getting too large or when you want to ensure critical information is preserved.", 
        "<cmd>optimize_context:{\"remove_files\": [\"path/to/file1.txt\"], \"pin_files\": [\"path/to/core.h\"], \"update_summary\": \"New summary text\"}</cmd>", 
        function(args, ctx, agent_name)
            local instructions = {}

            local json_match = utils.trim(args:gsub("`+", ""))
            
            if json_match ~= "" then
                local ok, parsed = pcall(function() return json:decode(json_match) end)
                if ok and type(parsed) == "table" then
                    instructions = parsed
                else
                    return { output = "\n[ERROR]: Invalid JSON format for optimize_context. Use: {\"remove_files\": [...], \"pin_files\": [...], \"update_summary\": \"...\"}" }
                end
            end

            local actions_taken = {}

            -- 1. Удаляем файлы из памяти
            if instructions.remove_files and type(instructions.remove_files) == "table" then
                for _, file_path in ipairs(instructions.remove_files) do
                    if ctx.knowledge_base[file_path] then
                        ctx.knowledge_base[file_path] = nil
                        ctx.file_states[file_path] = nil
                        ctx.file_access_rank[file_path] = nil
                        table.insert(actions_taken, "Removed file from memory: " .. file_path)
                    end
                end
            end

            -- 2. Пиним файлы
            if instructions.pin_files and type(instructions.pin_files) == "table" then
                for _, file_path in ipairs(instructions.pin_files) do
                    if ctx:pin_file(file_path) then
                        table.insert(actions_taken, "Pinned file: " .. file_path)
                    end
                end
            end

            -- 3. Обновляем саммари
            if instructions.update_summary and type(instructions.update_summary) == "string" then
                ctx:update_summary(instructions.update_summary)
                table.insert(actions_taken, "Updated task summary")
            end

            if #actions_taken == 0 then
                return { output = "\n[SYSTEM]: No optimizations were applied. The context is already optimal." }
            end

            return { output = "\n[SYSTEM]: Context optimized successfully.\nActions taken:\n" .. table.concat(actions_taken, "\n") }
        end
    )
end

return { register = register }
