local M = {}
local llm_handler = require("llm_handler")
local json = require("JSON")
local logger = require("logger")
local utils = require("utils")

function M.analyze_and_optimize(ctx, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then return end

    logger.info("[OPTIMIZER] Starting background context analysis...")
    
    -- 1. Собираем сжатый слепок контекста
    local loaded_files = {}
    for path, _ in pairs(ctx.knowledge_base) do table.insert(loaded_files, path) end
    
    local recent_actions = {}
    local start_idx = math.max(1, #ctx.last_actions - 5)
    for i = start_idx, #ctx.last_actions do
        table.insert(recent_actions, ctx.last_actions[i].summary)
    end
    
    local pinned_list = {}
    for k, _ in pairs(ctx.pinned_files or {}) do table.insert(pinned_list, k) end
    
    local context_brief = string.format(
        "TASK SUMMARY: %s\nCURRENT STEP: %d/%d\nLOADED FILES: %s\nRECENT ACTIONS: %s\nPINNED: %s",
        ctx.task_summary or "None",
        ctx.current_task_index,
        ctx.execution_plan and #ctx.execution_plan or 0,
        table.concat(loaded_files, ", "),
        table.concat(recent_actions, " | "),
        table.concat(pinned_list, ", ")
    )
    
    -- 2. Формируем промпт для Оптимизатора
    local prompt = string.format([[
You are an autonomous Context Optimization Agent. Your job is to analyze the current state of the main agent's memory and optimize it to prevent token overflow and maintain focus.

CURRENT CONTEXT BRIEF:
%s

INSTRUCTIONS:
1. Update the TASK SUMMARY to accurately reflect the current progress and next immediate goal.
2. Identify files that are NO LONGER NEEDED and should be removed from memory to save tokens.
3. Identify critical files that should be PINNED.

Respond STRICTLY with a valid JSON object. Do not include any markdown formatting or extra text.
{
  "new_summary": "Updated concise summary of the task and current state.",
  "files_to_remove": ["path/to/old_file.lua"],
  "files_to_pin": ["path/to/critical.h"]
}
]], context_brief)

    local messages = {
        { role = "system", content = "You are a Context Optimization AI. Output ONLY valid JSON." },
        { role = "user", content = prompt }
    }
    
    -- 3. Асинхронный (не стримящий) вызов к отдельной модели
    local res, err = llm_handler.send_request(opt_agent, messages, { override_params = { stream = false, temperature = 0.1 } })
    if not res then
        logger.warn("[OPTIMIZER] Failed to get response: " .. tostring(err))
        return
    end
    
    local content = llm_handler.extract_content(res)
    if not content then return end
    
    -- 4. Парсинг JSON (аналогично delegate_plan.lua)
    local json_match = utils.trim(content:gsub("`+", ""))
    local status, payload = pcall(function() return json:decode(json_match) end)

    if status and type(payload) == "table" then
        -- Применение оптимизаций к контексту
        if payload.new_summary and type(payload.new_summary) == "string" then
            ctx:update_summary(payload.new_summary)
            logger.info("[OPTIMIZER] Updated summary.")
        end
        
        if payload.files_to_remove and type(payload.files_to_remove) == "table" then
            for _, f in ipairs(payload.files_to_remove) do
                if ctx.knowledge_base[f] then
                    ctx.knowledge_base[f] = nil
                    ctx.file_states[f] = nil
                    ctx.file_access_rank[f] = nil
                    logger.info("[OPTIMIZER] Removed from memory: " .. f)
                end
            end
        end
        
        if payload.files_to_pin and type(payload.files_to_pin) == "table" then
            for _, f in ipairs(payload.files_to_pin) do
                if ctx.knowledge_base[f] then
                    ctx:pin_file(f)
                    logger.info("[OPTIMIZER] Pinned: " .. f)
                end
            end
        end
        
        logger.info("[OPTIMIZER] Cycle complete.")
    else
        local debug_snip = json_match:sub(1, 100) .. "..."
        logger.warn("[OPTIMIZER] Failed to parse JSON response. Engine saw: " .. debug_snip)
    end
end

return M
