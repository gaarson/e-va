local utils = require("utils")
local json = require("JSON")

local function register(registry)
    registry.register("delegate_plan", "Pass execution plan to next stage (JSON Object)", "<cmd>delegate_plan:\n{\n  \"plan\": [{\"file\": \"src/main.c\", \"instruction\": \"Fix bounds checking\"}],\n  \"memo\": \"Context for coder\"\n}\n</cmd>", function(args, ctx, agent_name)
        local json_match = utils.trim(args:gsub("`+", ""))

        local status, payload = pcall(function() return json:decode(json_match) end)

        local plan = nil
        local memo_text = ""

        if status and type(payload) == "table" then
            if type(payload.plan) == "table" then
                plan = payload.plan
                memo_text = payload.memo or ""
            elseif type(payload) == "table" then
                plan = payload
            end
        end

        if type(plan) == "table" and #plan > 0 then
            ctx.execution_plan = plan
            if type(memo_text) == "string" and memo_text ~= "" then 
                ctx.handoff_memo = utils.trim(memo_text) 
            end

            local loaded_files = {}
            for _, task in ipairs(plan) do
                if task.file then
                    local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)
                    if not ctx.knowledge_base[rel_path] then
                        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
                        local content = utils.read_file_range(full_path)
                        if content then
                            ctx:add_file(rel_path, content)
                            table.insert(loaded_files, rel_path)
                        end
                    end
                end
            end

            local auto_msg = ""
            if #loaded_files > 0 then
                auto_msg = " Auto-loaded targets into context: " .. table.concat(loaded_files, ", ")
            end

            return { output = "\n[SYSTEM]: Plan delegated successfully." .. auto_msg, signal = "PIPELINE_NEXT_STAGE" }
        end

        local debug_snip = json_match:sub(1, 100) .. "..."
        return { output = "\n[ERROR]: Invalid JSON plan format. Engine saw: " .. debug_snip, signal = nil }
    end)
end

return { register = register }