local M = {}
local utils   = require("utils")
local registry = require("tool_registry")

------------------------------------------------------------------------
-- States
------------------------------------------------------------------------
M.STATES = {
    IDLE              = "IDLE",
    INTENT_DRAFT      = "INTENT_DRAFT",
    INTENT_READY      = "INTENT_READY",
    COMMAND_READY     = "COMMAND_READY",
    REVIEWING         = "REVIEWING",
    APPROVED          = "APPROVED",
    REVISING          = "REVISING",
    COMPLETED         = "COMPLETED",
    ERROR             = "ERROR",
}

------------------------------------------------------------------------
-- Constructor
------------------------------------------------------------------------
function M.new(ctx, agent_name, opts)
    opts = opts or {}
    return setmetatable({
        ctx               = ctx,
        agent_name        = agent_name,
        state             = M.STATES.IDLE,
        task              = nil,
        intent            = nil,
        intent_raw        = nil,
        payload           = nil,
        last_result       = nil,
        review            = nil,
        corrections       = {},
        iteration         = 0,
        max_iterations    = opts.max_iterations or 3,
        prompts = {
            intent    = opts.intent_prompt    or M.DEFAULT_INTENT_PROMPT,
            generate  = opts.generate_prompt  or M.DEFAULT_GENERATE_PROMPT,
            review    = opts.review_prompt    or M.DEFAULT_REVIEW_PROMPT,
        },
    }, { __index = M })
end

------------------------------------------------------------------------
-- Parsers
------------------------------------------------------------------------
function M:parse_intent(text)
    if not text then return nil, "Empty response" end
    local block = text:match("<INTENT>(.-)</INTENT>")
    if not block then
        return nil, "No <INTENT>...</INTENT> block found in response."
    end

    local intent = {
        GOAL              = block:match("GOAL:%s*(.-)%s*\n") or "",
        TOOL              = block:match("TOOL:%s*(.-)%s*\n") or "",
        PAYLOAD_HINT      = block:match("PAYLOAD_HINT:%s*(.-)%s*\n") or "",
        SUCCESS_CRITERIA  = block:match("SUCCESS_CRITERIA:%s*(.-)%s*$") or "",
        raw               = utils.trim(block),
    }

    if intent.GOAL == "" then return nil, "Intent missing GOAL field." end
    if intent.TOOL == "" then return nil, "Intent missing TOOL field." end
    if intent.TOOL == "NONE" then
        return nil, "Agent reported no suitable tool available: " .. intent.GOAL
    end
    if not registry.tools[intent.TOOL] then
        return nil, string.format("Intent references unknown tool '%s'.", intent.TOOL)
    end

    return intent, nil
end

function M:parse_review(text)
    if not text then return nil, "Empty review response" end
    local block = text:match("<REVIEW>(.-)</REVIEW>")
    if not block then
        return nil, "No <REVIEW>...</REVIEW> block found."
    end

    local verdict = block:match("VERDICT:%s*(%S+)")
    if not verdict then return nil, "Review missing VERDICT field." end
    verdict = verdict:upper()
    if verdict ~= "APPROVE" and verdict ~= "REVISE" then
        return nil, "Invalid VERDICT: '" .. verdict .. "'. Expected APPROVE or REVISE."
    end

    local correction = nil
    if verdict == "REVISE" then
        correction = block:match("CORRECTION:%s*(.-)%s*</REVIEW>")
                   or block:match("CORRECTION:%s*(.-)%s*$")
        if not correction or utils.trim(correction) == "" then
            return nil, "VERDICT is REVISE but CORRECTION block is empty."
        end
        correction = utils.trim(correction)
    end

    return { verdict = verdict, correction = correction, raw = utils.trim(block) }, nil
end

------------------------------------------------------------------------
-- Prompt Builders
------------------------------------------------------------------------
function M:build_intent_prompt(task, project_context)
    local tools_list = {}
    for name, tool in pairs(registry.tools) do
        if registry.is_tool_allowed(self.ctx.config.AGENTS[self.agent_name], name) then
            tools_list[#tools_list + 1] = string.format("- %s: %s", name, tool.desc or "(no description)")
        end
    end
    table.sort(tools_list)

    return self.prompts.intent
        :gsub("{task_description}", task or "")
        :gsub("{project_context}", project_context or "")
        :gsub("{available_tools_list}", table.concat(tools_list, "\n"))
end

function M:build_generate_prompt()
    return self.prompts.generate:gsub("{intent_text}", self.intent_raw or "")
end

function M:build_review_prompt()
    return self.prompts.review
        :gsub("{intent_text}", self.intent_raw or "")
        :gsub("{payload_text}", self.payload or "")
        :gsub("{execution_output}", self.last_result or "")
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------
function M:start_task(task, project_context)
    self:reset()
    self.task   = task
    self.state  = M.STATES.INTENT_DRAFT
    self.iteration = 1
    return { stage = "intent", prompt = self:build_intent_prompt(task, project_context) }
end

function M:feed_response(llm_response)
    if self.state == M.STATES.INTENT_DRAFT then
        local intent, err = self:parse_intent(llm_response)
        if not intent then
            return { stage = "error", message = "Intent parse failed: " .. err }
        end
        self.intent     = intent
        self.intent_raw = intent.raw
        self.state      = M.STATES.INTENT_READY
        return { stage = "generate", prompt = self:build_generate_prompt() }
    end

    if self.state == M.STATES.INTENT_READY or self.state == M.STATES.REVISING then
        self.payload = llm_response
        self.state   = M.STATES.COMMAND_READY
        return { stage = "execute", tool = self.intent.TOOL, payload = self.payload }
    end

    if self.state == M.STATES.REVIEWING then
        local review, err = self:parse_review(llm_response)
        if not review then
            return { stage = "error", message = "Review parse failed: " .. err }
        end
        self.review = review

        if review.verdict == "APPROVE" then
            self.state = M.STATES.APPROVED
            return { stage = "done", result = self.last_result, iterations = self.iteration }
        end

        if self.iteration >= self.max_iterations then
            self.state = M.STATES.ERROR
            return {
                stage = "error",
                message = string.format("Failed to satisfy intent after %d iterations. Last correction: %s", self.iteration, review.correction)
            }
        end

        self.corrections[#self.corrections + 1] = review.correction
        self.intent_raw = self:_merge_correction(review.correction)
        self.state      = M.STATES.REVISING
        self.iteration  = self.iteration + 1
        return { stage = "generate", prompt = self:build_generate_prompt() }
    end

    return { stage = "error", message = "Unexpected state: " .. self.state }
end

function M:feed_execution_result(output)
    if self.state ~= M.STATES.COMMAND_READY then
        return { stage = "error", message = "Not in COMMAND_READY state." }
    end
    self.last_result = output
    self.state       = M.STATES.REVIEWING
    return { stage = "review", prompt = self:build_review_prompt() }
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
function M:_merge_correction(correction)
    return self.intent_raw
        .. "\n\n<REVISION iteration=\"" .. self.iteration .. "\">\n"
        .. "Previous attempt failed. Reviewer notes:\n"
        .. correction .. "\n"
        .. "Adjust PAYLOAD accordingly. Keep GOAL and SUCCESS_CRITERIA.\n"
        .. "</REVISION>"
end

function M:reset()
    self.state        = M.STATES.IDLE
    self.task         = nil
    self.intent       = nil
    self.intent_raw   = nil
    self.payload      = nil
    self.last_result  = nil
    self.review       = nil
    self.corrections  = {}
    self.iteration    = 0
end

------------------------------------------------------------------------
-- Default Prompts
------------------------------------------------------------------------
M.DEFAULT_INTENT_PROMPT = [[
Ты — архитектор действий. Твоя задача — НЕ выполнять команду, а ЧЁТКО СПЛАНИРОВАТЬ её.

Тебе передана задача:
<task>
{task_description}
</task>

Контекст проекта:
<context>
{project_context}
</context>

Доступные инструменты:
<tools>
{available_tools_list}
</tools>

Сформулируй намерение — план одной конкретной команды. НЕ пиши саму команду. Только спланируй.

Формат ответа (строго):

<INTENT>
GOAL: <что хотим получить в итоге, 1-2 предложения>
TOOL: <имя инструмента из списка>
PAYLOAD_HINT: <краткое описание содержимого команды>
SUCCESS_CRITERIA: <конкретные проверяемые критерии успеха>
</INTENT>

Правила:
1. GOAL — одна цель, конкретно.
2. TOOL — только из списка. Если не подходит — TOOL: NONE.
3. PAYLOAD_HINT — достаточно деталей, но не сам payload.
4. SUCCESS_CRITERIA — проверяемые утверждения, не "всё работает".
5. Не добавляй ничего вне тегов <INTENT>...</INTENT>.
6. Если задача большая — опиши ТОЛЬКО ПЕРВЫЙ этап.
]]

M.DEFAULT_GENERATE_PROMPT = [[
Ты — генератор команды. Преврати намерение в ГОТОВЫЙ payload.

Намерение:
{intent_text}

ВАЖНЕЙШЕЕ ПРАВИЛО:
Твой ответ будет ВСТАВЛЕН В PAYLOAD ИНСТРУМЕНТА 1-В-1.
Без парсинга. Без оборачивания. Без markdown. Без пояснений.

НЕЛЬЗЯ:
✗ Писать "Вот моя команда:" / "Вот содержимое:"
✗ Оборачивать в code fences✗ Добавлять комментарии до/после payload
✗ Использовать маркеры ||| COMMAND |||

НУЖНО:
✓ Писать ТОЛЬКО чистый payload
✓ Следовать PAYLOAD_HINT из намерения
✓ Если есть <REVISION> — учесть замечания ревьюера

Начинай сразу с первой строки payload. Заканчивай сразу после последней.
]]

M.DEFAULT_REVIEW_PROMPT = [[
Ты — ревьюер результата. Сравни результат с намерением.

Оригинальное намерение:
{intent_text}

Сгенерированный payload:
<payload>
{payload_text}
</payload>

Результат выполнения:
<result>
{execution_output}
</result>

Проверь по каждому пункту SUCCESS_CRITERIA.

Формат ответа (строго):

<REVIEW>
VERDICT: APPROVE | REVISE

CHECKLIST:
- [ ] <критерий 1>: PASS/FAIL — <комментарий>
- [ ] <критерий 2>: PASS/FAIL — <комментарий>

{Если REVISE — обязательно:}
CORRECTION:
<что конкретно не так>
<как исправить — направление>
</REVIEW>

Правила:
1. APPROVE — только если ВСЕ критерии PASS.
2. REVISE — если хотя бы один FAIL.
3. В CORRECTION пиши ЧТО исправить, не готовый payload.
4. Не добавляй ничего вне тегов <REVIEW>...</REVIEW>.
]]

return M
