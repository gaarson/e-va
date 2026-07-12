local utils = require("utils")
local json = require("JSON")
local logger = require("logger")

local function register(registry)
    registry.register("delegate_plan", "Pass execution plan to next stage (JSON Object)", "||| COMMAND |||\ndelegate_plan:\n{\n  \"plan\": [{\"file\": \"src/main.c\", \"instruction\": \"Fix bounds checking\"}],\n  \"memo\": \"Context for coder\"\n}\n||| END_COMMAND |||", function(args, ctx, agent_name)
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
            ctx.current_task_index = 1
            
            if type(memo_text) == "string" and memo_text ~= "" then
                ctx.handoff_memo = utils.trim(memo_text)
            end
            
            -- НОВЫЙ: Автоматически подгружаем файлы из плана
            local loaded_files = {}
            local max_files = 5 -- Ограничение на количество файлов в одном плане
            for _, task in ipairs(plan) do
                if task.file and #loaded_files < max_files then
                    local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)
                    if not ctx.knowledge_base[rel_path] then
                        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
                        local content = utils.read_file_range(full_path)
                        if content then
                            -- Проверка размера файла (не более 5000 токенов)
                            local token_count = ctx:estimate_tokens(content)
                            if token_count <= 5000 then
                                ctx:add_file(rel_path, content)
                                ctx:pin_file(rel_path)
                                table.insert(loaded_files, rel_path)
                            else
                                logger.warn(string.format("[DELEGATE] File %s too large (%d tokens), skipping.", rel_path, token_count))
                            end
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
    end,
    [[
    MULTI-STAGE GUIDE FOR `delegate_plan`:
    1. INTENT PHASE: In PAYLOAD_HINT, describe delegation scope - target agent, files, and overall goal.
       Example: "Delegate to CODER: implement 3 functions in src/parser.lua. Memo includes grammar rules."
    2. GENERATE PHASE: Output ONLY valid JSON with "plan" (array of {file, instruction}) and "memo" (rich context).
       If revising, fix JSON syntax, add missing files, or enrich the memo.
    3. CRITICAL: The memo is the MOST IMPORTANT field - it carries all context to the receiving agent.
       Each instruction must be atomic and verifiable.
    
    ]]
)
end

return { register = register }