local utils = require("utils")
local json = require("JSON")
local logger = require("logger")
local DELEGATE_PLAN_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        if not payload or utils.trim(payload) == "" then
            return false, "delegate_plan payload is empty."
        end
        local ok, parsed = pcall(function() return json:decode(payload) end)
        if not ok or type(parsed) ~= "table" then
            return false, "delegate_plan payload must be valid JSON."
        end
        if not parsed.plan or type(parsed.plan) ~= "table" or #parsed.plan == 0 then
            return false, "delegate_plan payload must contain a non-empty 'plan' array."
        end
        if not parsed.memo or utils.trim(parsed.memo) == "" then
            return false, "delegate_plan payload must contain a non-empty 'memo' field."
        end
        return true, nil
    end,
    estimate_complexity = function()
        return "complex"
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = [[
PAYLOAD FORMAT FOR `delegate_plan`:
Output ONLY valid JSON with "plan" (array of {file, instruction}) and "memo" (rich context).
Do NOT wrap in code fences. Do NOT add explanations.
{
  "plan": [
    {"file": "src/main.c", "instruction": "Fix bounds checking"},
    {"file": "src/utils.c", "instruction": "Add helper function"}
  ],
  "memo": "Detailed context for the receiving agent about what needs to be done and why."
}
RULES:
- Each instruction must be atomic and verifiable.
- The memo is the MOST IMPORTANT field - it carries all context to the receiving agent.
- Make the memo rich enough for a blind agent to understand the context.
]],
    review_checks = [[
TOOL-SPECIFIC REVIEW CHECKS FOR `delegate_plan`:
- [ ] Is the payload valid JSON?
- [ ] Does the 'plan' array contain at least one step?
- [ ] Does each step have a 'file' and 'instruction' field?
- [ ] Is the 'memo' field rich and descriptive enough for the receiving agent?
- [ ] Are the instructions atomic and verifiable?
- [ ] If revision was requested, were the reviewer's corrections applied correctly?
]],
    intent_guideline = "- `delegate_plan`: Use when delegating work to another agent. Describe what the receiving agent needs to accomplish and what context they need.",
    multi_stage_docs = [[
This tool is marked [MS] (Multi-Stage). When you see this tag, use the SHORT-FORM command: output ONLY `delegate_plan:` WITHOUT any JSON payload. The system will automatically guide you through Intent → Generate → Review to produce the correct payload. DO NOT include JSON in your initial command — the multi-stage pipeline will generate it for you after you specify the goal and delegation scope.
]],
}
local function register(registry)
    registry.register("delegate_plan", "Delegates execution plan to next agent (CODER). Auto-loads up to 15 target files into context (max 15000 tokens each) and pins them. Triggers PIPELINE_NEXT_STAGE signal.", "||| COMMAND |||\ndelegate_plan:\n{\n  \"plan\": [{\"file\": \"src/main.c\", \"instruction\": \"Fix bounds checking in array access\"}],\n  \"memo\": \"The CODER agent is BLIND. This memo is their ONLY context. Include: what to do, why, exact file paths, expected behavior, constraints, and any relevant code snippets or patterns.\"\n}\n||| END_COMMAND |||\n\nJSON SCHEMA:\n{\n  \"plan\": [{\"file\": \"<path>\", \"instruction\": \"<atomic task>\"}],\n  \"memo\": \"<rich context string>\"\n}\n\nRULES:\n- 'plan' must be non-empty array. Each item needs 'file' and 'instruction'.\n- 'memo' is CRITICAL: the receiving agent sees ONLY this + auto-loaded files.\n- Instructions must be atomic and verifiable.\n- Backticks in JSON are stripped before parsing.\n\nSIDE-EFFECTS:\n- Auto-loads up to 15 files from plan into knowledge_base (max 15000 tokens/file).\n- All loaded files are PINNED (survive context compression).\n- Sets ctx.execution_plan and ctx.current_task_index=1.\n- Returns signal PIPELINE_NEXT_STAGE (advances pipeline).\n- MS SHORT-FORM: 'delegate_plan:' (no JSON) routes to multi-stage pipeline.", function(args, ctx, agent_name)
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
            local skipped_files = {}
            local pinned_files_list = {}
            local max_files = 15 -- Increased from 5 to 15
            local max_tokens_per_file = 15000 -- Increased from 5000 to 15000
            for _, task in ipairs(plan) do
                if task.file and #loaded_files < max_files then
                    local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)
                    if not ctx.knowledge_base[rel_path] then
                        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
                        local content = utils.read_file_range(full_path)
                        if content then
                            -- Проверка размера файла (не более 15000 токенов)
                            local token_count = ctx:estimate_tokens(content)
                            if token_count <= max_tokens_per_file then
                                ctx:add_file(rel_path, content)
                                ctx:pin_file(rel_path)
                                table.insert(loaded_files, rel_path)
                                table.insert(pinned_files_list, string.format("%s (%d tokens)", rel_path, token_count))
                            else
                                table.insert(skipped_files, rel_path .. " (" .. token_count .. " tokens)")
                                logger.warn(string.format("[DELEGATE] File %s too large (%d tokens), skipping.", rel_path, token_count))
                            end
                        end
                    end
                end
            end
            -- Add pin_files array to plan payload for context_flow awareness
            if type(payload) == "table" then
                payload.pin_files = loaded_files
            end
            local auto_msg = ""
            if #skipped_files > 0 then
                auto_msg = auto_msg .. "\n[WARNING] Files too large to auto-load (use read_file manually): " .. table.concat(skipped_files, ", ")
            end
            if #loaded_files > 0 then
                auto_msg = " Auto-loaded targets into context: " .. table.concat(loaded_files, ", ")
                auto_msg = auto_msg .. "\n[PINNED CONFIRMATION] The following files are pinned and prioritized:\n"
                for _, pf in ipairs(pinned_files_list) do
                    auto_msg = auto_msg .. "  - " .. pf .. "\n"
                end
            end
            return { output = "\n[SYSTEM]: Plan delegated successfully." .. auto_msg, signal = "PIPELINE_NEXT_STAGE" }
        end
        local debug_snip = json_match:sub(1, 100) .. "..."
        return { output = "\n[ERROR]: Invalid JSON plan format. Engine saw: " .. debug_snip, signal = nil }
    end,
    DELEGATE_PLAN_MANIFEST.multi_stage_docs,
    DELEGATE_PLAN_MANIFEST)
end
return { register = register }