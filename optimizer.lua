local M = {}
local llm_handler = require("llm_handler")
local json = require("JSON")
local logger = require("logger")
local utils = require("utils")

function M.analyze_and_optimize(ctx, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then 
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return 
    end

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

    local thoughts_text = ctx:get_recent_thoughts_text()

    local context_brief = string.format(
        "TASK SUMMARY: %s\nCURRENT STEP: %d/%d\nLOADED FILES: %s\nRECENT ACTIONS: %s\nPINNED: %s\n",
        ctx.task_summary or "None",
        ctx.current_task_index,
        ctx.execution_plan and #ctx.execution_plan or 0,
        table.concat(loaded_files, ", "),
        table.concat(recent_actions, " | "),
        table.concat(pinned_list, ", "),
        thoughts_text
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

function M.extract_and_optimize_prompt(ctx, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then 
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return nil 
    end

    -- 1. Extract the current prompt from prompt_history
    local current_prompt = nil
    if ctx.prompt_history and #ctx.prompt_history > 0 then
        current_prompt = ctx.prompt_history[#ctx.prompt_history]
    end

    if not current_prompt then
        logger.warn("[OPTIMIZER] No prompt found in prompt_history.")
        return nil
    end

    logger.info("[OPTIMIZER] Starting prompt optimization...")

    -- 2. Form the optimization request
    local prompt = string.format([[
You are an expert Prompt Optimization Agent. Your job is to analyze and improve the given prompt for clarity, conciseness, and effectiveness.

CURRENT PROMPT:
%s

INSTRUCTIONS:
1. Improve the prompt's clarity and structure
2. Remove any redundant or unnecessary information
3. Ensure the prompt is concise while maintaining all critical instructions
4. Return ONLY the optimized prompt text, nothing else

Return the optimized prompt as plain text without any markdown formatting or extra text.
]], current_prompt)

    local messages = {
        { role = "system", content = "You are a Prompt Optimization AI. Output ONLY the optimized prompt text." },
        { role = "user", content = prompt }
    }

    -- 3. Send to LLM for optimization (non-streaming)
    local res, err = llm_handler.send_request(opt_agent, messages, { override_params = { stream = false, temperature = 0.1 } })
    if not res then
        logger.warn("[OPTIMIZER] Failed to get response: " .. tostring(err))
        return nil
    end

    local content = llm_handler.extract_content(res)
    if not content then 
        logger.warn("[OPTIMIZER] No content in response.")
        return nil 
    end

    -- 4. Clean up the response (remove markdown code blocks if present)
    local optimized_prompt = utils.trim(content:gsub("`+", ""))

    logger.info("[OPTIMIZER] Prompt optimization complete.")
    return optimized_prompt
end

function M.summarize_unclosed_thought(unclosed_text, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then 
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return nil 
    end

    if not unclosed_text or #utils.trim(unclosed_text) == 0 then
        logger.warn("[OPTIMIZER] No unclosed text provided.")
        return nil
    end

    logger.info("[OPTIMIZER] Summarizing unclosed thought...")

    -- Form the summarization request
    local prompt = string.format([[
You are an expert Thought Summarization Agent. Your job is to analyze incomplete or unclosed thinking text and summarize it into a concise, actionable output.

UNCLOSED THOUGHT:
%s

INSTRUCTIONS:
1. Identify the core intent and key points of the incomplete thought
2. Summarize the thought in 1-3 concise sentences
3. Focus on actionable insights or next steps
4. Return ONLY the summarized text, nothing else

Return the summary as plain text without any markdown formatting or extra text.
]], unclosed_text)

    local messages = {
        { role = "system", content = "You are a Thought Summarization AI. Output ONLY the concise summary." },
        { role = "user", content = prompt }
    }

    -- Non-streaming call to the optimizer model
    local res, err = llm_handler.send_request(opt_agent, messages, { override_params = { stream = false, temperature = 0.1 } })
    if not res then
        logger.warn("[OPTIMIZER] Failed to get response: " .. tostring(err))
        return nil
    end

    local content = llm_handler.extract_content(res)
    if not content then return nil end

    -- Clean up the response
    local summary = utils.trim(content:gsub("`+", ""))

    if #summary > 0 then
        logger.info("[OPTIMIZER] Summarized unclosed thought.")
        return summary
    else
        logger.warn("[OPTIMIZER] Empty summary returned.")
        return nil
    end
end

function M.generate_continuation_prompt(ctx, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return nil
    end

    -- 1. Gather context: last assistant message, task summary, execution plan
    local last_assistant = ""
    if ctx.history and type(ctx.history) == "table" then
        -- Walk backwards through history to find last assistant message
        for i = #ctx.history, 1, -1 do
            local msg = ctx.history[i]
            if msg and msg.role == "assistant" and msg.content and #msg.content > 0 then
                last_assistant = msg.content
                break
            end
        end
    end

    local task_summary = ctx.task_summary or "No task summary available."

    local plan_text = "No execution plan."
    if ctx.execution_plan and #ctx.execution_plan > 0 then
        plan_text = ""
        for i, step in ipairs(ctx.execution_plan) do
            plan_text = plan_text .. i .. ". " .. (step.description or step.summary or step) .. "\n"
        end
    end

    local recent_actions = ""
    if ctx.last_actions and #ctx.last_actions > 0 then
        local actions_list = {}
        local start_idx = math.max(1, #ctx.last_actions - 3)
        for i = start_idx, #ctx.last_actions do
            table.insert(actions_list, ctx.last_actions[i].summary or ctx.last_actions[i].command or "unknown action")
        end
        recent_actions = table.concat(actions_list, " | ")
    end

    logger.info("[OPTIMIZER] Generating smart continuation prompt...")

    -- 2. Build prompt
    local prompt = string.format([[
You are a Continuation Prompt Generator. Analyze the current conversation state and generate a concise follow-up message to guide the main agent.

TASK SUMMARY: %s
CURRENT PLAN: %s
RECENT ACTIONS: %s
LAST ASSISTANT MESSAGE: %s

Generate a single concise message (1-3 sentences) that:
1. Acknowledges the current state
2. Asks a specific question or gives a clear direction
3. Helps the agent continue productively

Output ONLY the message text, nothing else.
]], task_summary, plan_text, recent_actions, last_assistant)

    local messages = {
        { role = "system", content = "You are a Continuation Prompt Generator. Output ONLY the concise follow-up message." },
        { role = "user", content = prompt }
    }

    -- 3. Non-streaming call to optimizer model
    local res, err = llm_handler.send_request(opt_agent, messages, { override_params = { stream = false, temperature = 0.3, max_tokens = 256 } })
    if not res then
        logger.warn("[OPTIMIZER] Failed to generate continuation prompt: " .. tostring(err))
        return nil
    end

    local content = llm_handler.extract_content(res)
    if not content then
        logger.warn("[OPTIMIZER] No content in continuation prompt response.")
        return nil
    end

    -- 4. Clean up
    local continuation = utils.trim(content:gsub("`+", ""))

    if #continuation > 0 then
        logger.info("[OPTIMIZER] Generated continuation prompt: " .. continuation:sub(1, 80) .. "...")
        return continuation
    else
        logger.warn("[OPTIMIZER] Empty continuation prompt returned.")
        return nil
    end
end

return M