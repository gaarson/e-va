local utils = require("utils")
local registry = require("tool_registry")
local logger = require("logger")
local states = require("multi_stage_executor.states")
local prompts = require("multi_stage_executor.prompts")
local parsers = require("multi_stage_executor.parsers")

local M = {}

function M.new(ctx, agent_name, opts)
    opts = opts or {}
    return setmetatable({
        ctx               = ctx,
        agent_name        = agent_name,
        state             = states.STATES.IDLE,
        task              = nil,
        intent            = nil,
        intent_raw        = nil,
        payload           = nil,
        last_result       = nil,
        review            = nil,
        corrections       = {},
        iteration         = 0,
        max_iterations    = opts.max_iterations or 3,
        total_tokens_used = 0,
        max_tokens_per_task = opts.max_tokens_per_task or 32000,
        budget_mode       = opts.budget_mode or "adaptive",
        file_path         = opts.file_path or nil,
        project_context   = nil,
        validation_retries = 0,
        max_validation_retries = opts.max_validation_retries or 2,
        tool_failures     = {},          -- Fix #6: per-tool failure tracking
        partial_passed_criteria = {},    -- Fix #7: track which criteria passed in PARTIAL
        prompts = {
            intent    = opts.intent_prompt    or prompts.DEFAULT_INTENT_PROMPT,
            generate  = opts.generate_prompt  or prompts.DEFAULT_GENERATE_PROMPT,
            review    = opts.review_prompt    or prompts.DEFAULT_REVIEW_PROMPT,
        },

    }, { __index = M })

end


function M:parse_intent(text)
    if not text then return nil, "Empty response" end
    local block = text:match("<INTENT>(.-)</INTENT>")

    if not block then
        return nil, "No <INTENT>...</INTENT> block found in response."
    end

    local intent = {
        GOAL             = parsers.extract_field(block, "GOAL"),
        TOOL             = parsers.extract_field(block, "TOOL"),
        FILE_PATH        = parsers.extract_field(block, "FILE_PATH"),
        PAYLOAD_HINT     = parsers.extract_field(block, "PAYLOAD_HINT"),
        SUCCESS_CRITERIA = parsers.extract_field(block, "SUCCESS_CRITERIA"),
        raw              = utils.trim(block),
    }

    intent.TOOL = (intent.TOOL:match("^%S+") or "")
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

    if verdict ~= "APPROVE" and verdict ~= "REVISE" and verdict ~= "PARTIAL" then
        return nil, "Invalid VERDICT: '" .. verdict .. "'. Expected APPROVE, REVISE, or PARTIAL."
    end
    local correction = nil
    if verdict == "REVISE" or verdict == "PARTIAL" then
        correction = parsers.extract_field(block, "CORRECTION")
        if correction == "" then
            return nil, "VERDICT is REVISE but CORRECTION block is empty."
        end
    end

    return { verdict = verdict, correction = correction, raw = utils.trim(block), partial_passed = verdict == "PARTIAL" }, nil
end


function M:build_intent_prompt(task, project_context)
    local tools_list = {}
    local guidelines = {}
    for name, tool in pairs(registry.tools) do
        if registry.is_tool_allowed(self.ctx.config.AGENTS[self.agent_name], name) then
            tools_list[#tools_list + 1] = string.format("- %s: %s", name, tool.desc or "(no description)")
            -- Collect intent guidelines from manifests
            if tool.manifest and tool.manifest.intent_guideline then
                guidelines[#guidelines + 1] = tool.manifest.intent_guideline
            end
        end
    end
    table.sort(tools_list)
    local guidelines_str = ""
    if #guidelines > 0 then
        guidelines_str = "\n\nTOOL SELECTION GUIDELINES:\n" .. table.concat(guidelines, "\n")
    end
    return parsers.render(self.prompts.intent, {
        task_description     = task or "",
        project_context      = project_context or "",
        available_tools_list = table.concat(tools_list, "\n"),
        tool_selection_guidelines = guidelines_str,
    })
end

function M:build_generate_system_context()
    local tool_name = self.intent and self.intent.TOOL or ""
    local tool = registry.tools[tool_name]
    local tool_hint = ""
    if tool and tool.manifest then
        if type(tool.manifest.generate_hint) == "function" then
            tool_hint = tool.manifest.generate_hint()
        elseif tool.manifest.generate_hint then
            tool_hint = tool.manifest.generate_hint
        end
    end
    local hint_block = ""
    if tool_hint ~= "" then
        hint_block = "\n\n" .. tool_hint
    end
    -- Build context block from knowledge_base (relevant source files)
    local context_block = ''
    local max_context_chars = 16000
    local collected = {}
    local total_len = 0
    if self.ctx and self.ctx.knowledge_base then
        local kb = self.ctx.knowledge_base
        local intent_text = self.intent_raw or ''
        local task_text = self.task or ''
        local file_path = self.file_path or ''
        for path, file_content in pairs(kb) do
            if total_len < max_context_chars then
                local is_relevant = false
                if intent_text:find(path, 1, true) then
                    is_relevant = true
                elseif task_text:find(path, 1, true) then
                    is_relevant = true
                end
                if file_path ~= '' and path == file_path then
                    is_relevant = true
                end
                if is_relevant then
                    local remaining = max_context_chars - total_len
                    local fc = file_content
                    if #fc > remaining - 50 then
                        fc = fc:sub(1, math.max(remaining - 50, 0)) .. '\n...[truncated]'
                    end
                    local block = string.format('<file path="%s">\n%s\n</file>', path, fc)
                    collected[#collected + 1] = block
                    total_len = total_len + #block
                end
            end
        end
    end
    -- If target file not in KB, try reading from disk
    if self.file_path and self.file_path ~= '' then
        local already_included = false
        for _, block in ipairs(collected) do
            if block:find(self.file_path, 1, true) then
                already_included = true
                break
            end
        end
        if not already_included and self.ctx and self.ctx.config and self.ctx.config.PROJECT_ROOT then
            local full_path = self.ctx.config.PROJECT_ROOT .. '/' .. self.file_path
            local f = io.open(full_path, 'r')
            if f then
                local fc = f:read('*a')
                f:close()
                local remaining = max_context_chars - total_len
                if remaining > 100 then
                    if #fc > remaining - 50 then
                        fc = fc:sub(1, math.max(remaining - 50, 0)) .. '\n...[truncated]'
                    end
                    local block = string.format('<file path="%s">\n%s\n</file>', self.file_path, fc)
                    collected[#collected + 1] = block
                end
            end
        end
    end
    if #collected > 0 then
        local sep = '\n'
        context_block = sep .. '<project_context>' .. sep .. 'Relevant source files for reference (use as ground truth):' .. sep .. table.concat(collected, sep) .. sep .. '</project_context>'
    end
    -- Include thinking history so generate stage has awareness of prior reasoning
    if self.ctx and self.ctx.thoughts and #self.ctx.thoughts > 0 then
        local thoughts_lines = {}
        for _, th in ipairs(self.ctx.thoughts) do
            table.insert(thoughts_lines, th.content)
        end
        context_block = context_block .. '\n\n<thinking_history>\n' .. table.concat(thoughts_lines, '\n') .. '\n</thinking_history>'
    end
    local template = self.prompts.generate_system or prompts.DEFAULT_GENERATE_SYSTEM
    return parsers.render(template, {
        context_block = context_block,
        tool_specific_hint = hint_block,
    })
end
function M:build_generate_user_message()
    local tool_name = self.intent and self.intent.TOOL or ""
    local feedback_block = ""
    if self.tool_failures and self.tool_failures[tool_name] and self.tool_failures[tool_name] >= 2 then
        feedback_block = "\n\n<FEEDBACK>\nThis tool ('" .. tool_name .. "') has failed " .. self.tool_failures[tool_name] .. " times previously.\nReview past corrections carefully and ensure the payload addresses ALL previous issues.\n</FEEDBACK>"
    end
    local template = self.prompts.generate_user or prompts.DEFAULT_GENERATE_USER
    return parsers.render(template, {
        intent_text = self.intent_raw or "",
        feedback_block = feedback_block,
    })
end
-- DEPRECATED: Kept for backward compatibility with tests.
function M:build_generate_prompt()
    return self:build_generate_system_context() .. "\n\n" .. self:build_generate_user_message()
end

function M:build_review_prompt()
    local tool_name = self.intent and self.intent.TOOL or ""
    local tool = registry.tools[tool_name]
    local tool_checks = ""
    if tool and tool.manifest then
        if type(tool.manifest.review_checks) == "function" then
            tool_checks = tool.manifest.review_checks()
        elseif tool.manifest.review_checks then
            tool_checks = tool.manifest.review_checks
        end
    end
    local checks_block = ""
    if tool_checks ~= "" then
        checks_block = "\n\n" .. tool_checks
    end

    return parsers.render(self.prompts.review, {
        intent_text      = self.intent_raw or "",
        payload_text     = self.payload or "",
        execution_output = self.last_result or "",
        tool_specific_checks = checks_block,
    })

end


function M:start_task_with_intent(task, project_context, tool_name, payload_hint, success_criteria, file_path)
    self:reset()

    if file_path and file_path ~= "" then
        self.file_path = utils.trim(file_path)
    end

    if not tool_name or utils.trim(tool_name) == "" then
        return { stage = "error", message = "start_task_with_intent: tool_name is empty." }
    end

    if not registry.tools[tool_name] then
        return { stage = "error", message = string.format("start_task_with_intent: unknown tool '%s'.", tool_name) }
    end

    local agent_cfg = self.ctx.config.AGENTS[self.agent_name]

    if agent_cfg and not registry.is_tool_allowed(agent_cfg, tool_name) then
        return { stage = "error", message = string.format("start_task_with_intent: tool '%s' is not allowed for agent '%s'.", tool_name, self.agent_name) }
    end

    local complexity = parsers.estimate_complexity(tool_name, payload_hint, file_path)

    if complexity == "simple" then
        self.max_iterations = 1
        logger.info(string.format("[MULTI-STAGE] Complexity heuristic: '%s' classified as SIMPLE. Limiting to 1 iteration (simple task). Review still runs but cannot revise.", tool_name))
    end

    self.task      = task
    self.project_context = project_context or ''
    self.intent    = {
        GOAL             = task or "",
        TOOL             = tool_name,
        FILE_PATH        = self.file_path or "",
        PAYLOAD_HINT     = payload_hint or "",
        SUCCESS_CRITERIA = success_criteria or "",
        raw              = string.format("GOAL: %s\nTOOL: %s\nFILE_PATH: %s\nPAYLOAD_HINT: %s\nSUCCESS_CRITERIA: %s",
            task or "", tool_name or "", self.file_path or "", payload_hint or "", success_criteria or ""),
    }

    self.intent_raw = self.intent.raw
    self.state      = states.STATES.INTENT_READY
    self.iteration  = 1
    return { stage = "generate", system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }

end

function M:build_intent_validation_prompt(project_context)
    local intent_text = self.intent_raw or ""
    return string.format([[
You are an Intent Validator. Review the following planned intent and confirm it is correct and actionable.

<INTENT>
%s
</INTENT>

Project context:
<context>
%s
</context>

Rules:
1. If the intent is correct, actionable, and references a valid tool — respond with ONLY: CONFIRM
2. If something is wrong (wrong tool, missing file path, unclear goal) — respond with:
CORRECTION: <specific fix needed>
3. Do NOT add anything else.
]], intent_text, project_context or "")
end


function M:start_task(task, project_context)
    self:reset()

    self.task      = task
    self.project_context = project_context or ''
    self.state     = states.STATES.INTENT_DRAFT

    self.iteration = 1

    return { stage = "intent", prompt = self:build_intent_prompt(task, project_context) }
end


function M:calculate_token_budget()
    local mode = self.budget_mode
    local ctx = self.ctx
    local config = ctx and ctx.config
    if mode == "fixed" then
        return self.max_tokens_per_task
    elseif mode == "aggressive" then
        if config and config.LIMITS then
            local available = config.LIMITS.MAX_CONTEXT - config.LIMITS.RESERVED_OUTPUT - config.LIMITS.SYSTEM_PROMPT_ESTIMATE
            return math.floor(available * 0.8)
        end
        return self.max_tokens_per_task
    else
        if config and config.LIMITS then
            local available = config.LIMITS.MAX_CONTEXT - config.LIMITS.RESERVED_OUTPUT - config.LIMITS.SYSTEM_PROMPT_ESTIMATE
            return math.floor(available * 0.6)
        end

        return self.max_tokens_per_task
    end

end


function M:feed_response(llm_response)
    -- Estimate tokens used by this response (rough: chars / 4)
    local tokens_used = 0
    if llm_response and type(llm_response) == "string" then
        local chars_per_token = (self.ctx.config.LIMITS and self.ctx.config.LIMITS.CHARS_PER_TOKEN) or 3.5
        tokens_used = math.floor(#llm_response / chars_per_token)
    end
    if self.state == states.STATES.INTENT_DRAFT then
        self.total_tokens_used = self.total_tokens_used + tokens_used
        local intent, err = self:parse_intent(llm_response)
        if not intent then
            return { stage = "error", message = "Intent parse failed: " .. err }
        end
        self.intent     = intent
        self.intent_raw = intent.raw
        if (intent.TOOL == "patch" or intent.TOOL == "create_file") and intent.FILE_PATH and utils.trim(intent.FILE_PATH) ~= "" then
            self.file_path = utils.trim(intent.FILE_PATH)
        end
        self.state      = states.STATES.INTENT_READY
        return { stage = "generate", system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }
    end

    -- FIX #2: Handle intent validation response
    if self.state == states.STATES.INTENT_READY and self.pending_intent_validation then
        self.total_tokens_used = self.total_tokens_used + tokens_used
        self.pending_intent_validation = false
        local upper_resp = (llm_response or ""):upper()
        if upper_resp:find("^%s*CONFIRM") then
            logger.info("[MULTI-STAGE] Intent validated: CONFIRM")
            return { stage = "generate", system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }
        end
        local correction = llm_response:match("CORRECTION:%s*(.*)")
        if correction and utils.trim(correction) ~= "" then
            logger.info(string.format("[MULTI-STAGE] Intent corrections: %s", utils.trim(correction):sub(1, 200)))
            self.intent_raw = self.intent_raw .. "\n\n[INTENT VALIDATION] " .. utils.trim(correction):sub(1, 300)
        end
        return { stage = "generate", system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }
    end
    if self.state == states.STATES.INTENT_READY or self.state == states.STATES.REVISING then
        self.total_tokens_used = self.total_tokens_used + tokens_used
        self.payload = parsers.sanitize_payload(llm_response)
        local valid, err_msg = parsers.validate_payload(self.intent.TOOL, self.payload)
        if not valid then
            self.validation_retries = self.validation_retries + 1
            if self.validation_retries > self.max_validation_retries then
                logger.warn(string.format("[MULTI-STAGE] Payload validation failed after %d retries for tool '%s': %s", self.validation_retries, self.intent.TOOL, err_msg))
                self.state = states.STATES.ERROR
                return { stage = "error", message = "Payload validation failed after " .. self.validation_retries .. " retries: " .. err_msg }
            end
            logger.warn(string.format("[MULTI-STAGE] Payload validation failed (attempt %d/%d) for tool '%s': %s. Requesting regeneration.", self.validation_retries, self.max_validation_retries, self.intent.TOOL, err_msg))
            self.corrections[#self.corrections + 1] = "PAYLOAD VALIDATION ERROR: " .. err_msg .. ". Please fix the payload to satisfy validation requirements."
            self.intent_raw = self:_merge_correction("PAYLOAD VALIDATION ERROR: " .. err_msg .. ". Please fix the payload to satisfy validation requirements.")
            self.state = states.STATES.REVISING
            self.iteration = self.iteration + 1
            return { stage = "generate", system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }
        end

        self.state   = states.STATES.COMMAND_READY
        local effective_payload = self.payload

        if (self.intent.TOOL == "patch" or self.intent.TOOL == "create_file") and self.file_path and self.file_path ~= "" then
            if self.payload:sub(1, #self.file_path) ~= self.file_path then
                effective_payload = self.file_path .. "\n" .. self.payload
            end
        end

        return { stage = "execute", tool = self.intent.TOOL, payload = effective_payload }
    end

    if self.state == states.STATES.REVIEWING then
        self.total_tokens_used = self.total_tokens_used + tokens_used
        local budget = self:calculate_token_budget()

        if self.total_tokens_used > budget then
            logger.warn(string.format(
                "[MULTI-STAGE] Token budget exceeded (%d/%d, mode=%s). Force-approving.",
                self.total_tokens_used, budget, self.budget_mode
            ))
            self.state = states.STATES.APPROVED
            return { stage = "done", result = self.last_result, iterations = self.iteration, forced_approval = true }
        end

        local review, err = self:parse_review(llm_response)

        if not review then
            local upper_resp = llm_response:upper()
            local inferred_verdict = nil
            -- (1) Check for explicit VERDICT: line first
            local verdict_line = llm_response:match("VERDICT:%s*(%S+)")
            if verdict_line then
                verdict_line = verdict_line:upper()
                if verdict_line == "APPROVE" then
                    inferred_verdict = "APPROVE"
                elseif verdict_line == "REVISE" then
                    inferred_verdict = "REVISE"
                end
            end
            -- (2) Keyword inference from upper-cased response
            if not inferred_verdict then
                if upper_resp:find("APPROVE") and not upper_resp:find("REVISE") then
                    inferred_verdict = "APPROVE"
                elseif upper_resp:find("REVISE") then
                    inferred_verdict = "REVISE"
                end
            end
            -- (3) Safe default
            local final_verdict = inferred_verdict or "REVISE"
            if inferred_verdict then
                logger.warn(string.format("[MULTI-STAGE] Review parse failed. Inferred verdict: %s from keywords. Error: %s", final_verdict, err))
            else
                logger.warn(string.format("[MULTI-STAGE] Review parse failed and no VERDICT line found. Defaulting to REVISE (safe fallback). Error: %s", err))
            end
            self.review = { verdict = final_verdict, correction = "Reviewer response could not be parsed into a structured verdict. Please regenerate with clearer output.", raw = utils.trim(llm_response) }
        else

            self.review = review

        end

        if self.review.verdict == "APPROVE" then
            self.state = states.STATES.APPROVED
            return { stage = "done", result = self.last_result, iterations = self.iteration }
        end
        if self.review.verdict == "PARTIAL" then
            -- Partial approval: log which parts passed, treat as REVISE for the failed parts
            logger.info(string.format("[MULTI-STAGE] PARTIAL approval: some criteria passed, revising failed parts."))
            self.state = states.STATES.PARTIAL
            if self.iteration >= self.max_iterations then
                -- If we've exhausted iterations, force-approve the partial result
                logger.warn("[MULTI-STAGE] Partial approval with max iterations reached. Force-approving partial result.")
                self.state = states.STATES.APPROVED
                return { stage = "done", result = self.last_result, iterations = self.iteration, partial_approval = true }
            end
            self.corrections[#self.corrections + 1] = self.review.correction
            self.intent_raw = self:_merge_correction(self.review.correction)
            self.state = states.STATES.REVISING
            self.iteration = self.iteration + 1
            return { stage = "generate", system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }
        end
        if self.review.verdict == "REVISE" then
            if self.iteration >= self.max_iterations then
                self.state = states.STATES.ERROR

                return {
                    stage = "error",
                    message = string.format(
                        "Failed to satisfy intent after %d iterations. Last correction: %s",
                        self.iteration, self.review.correction
                    ),
                }
            end

            self.corrections[#self.corrections + 1] = self.review.correction
            self.intent_raw = self:_merge_correction(self.review.correction)
            self.state      = states.STATES.REVISING
            self.iteration  = self.iteration + 1

            return { stage = "generate", system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }

        end
    end

    return { stage = "error", message = "Unexpected state: " .. self.state }
end

function M:feed_execution_result(output)
    if self.state ~= states.STATES.COMMAND_READY then
        return { stage = "error", message = "Not in COMMAND_READY state." }
    end

    local output_str

    local signal_str

    if type(output) == "table" then
        output_str = output.output ~= nil and tostring(output.output) or ""
        signal_str = output.signal ~= nil and tostring(output.signal) or ""
    elseif type(output) == "string" then
        output_str = output
        signal_str = ""
    else
        output_str = tostring(output or "")
        signal_str = ""
    end

    local result_parts = {}

    if signal_str ~= "" then
        table.insert(result_parts, string.format("[SIGNAL] %s", signal_str))
    end

    if output_str ~= "" then
        table.insert(result_parts, string.format("[OUTPUT] %s", output_str))
    end

    local enriched_result = table.concat(result_parts, "\n")

    if enriched_result == "" then
        enriched_result = "<empty output>"
    end

    local tool_name = self.intent and self.intent.TOOL or ""
    local tool = registry.tools[tool_name]
    if tool and tool.manifest and tool.manifest.enrich_result then
        enriched_result = tool.manifest.enrich_result(enriched_result, self.ctx, self.payload, self.intent, self.file_path)
    end

    self.last_result = enriched_result
    -- FIX #6: Track tool failures for feedback in generate prompt
    local has_failure = (signal_str:find('FAILURE') ~= nil) or (output_str:find('%[PATCH FAILED%]') ~= nil) or (output_str:find('%[ERROR%]') ~= nil) or (output_str:find('%[DISK ERROR%]') ~= nil)
    if has_failure then
        self.tool_failures[tool_name] = (self.tool_failures[tool_name] or 0) + 1
        logger.info(string.format("[MULTI-STAGE] Tool failure detected for '%s' (count: %d)", tool_name, self.tool_failures[tool_name]))
    end
    -- FIX #5: If execution failed and we have iterations left, retry generation instead of reviewing
    if has_failure and self.iteration < self.max_iterations then
        local error_snippet = output_str:sub(1, 500)
        local correction = 'EXECUTION FAILED: ' .. error_snippet .. '. Fix the payload to avoid this error.'
        logger.info(string.format('[MULTI-STAGE] Execution failed, retrying generation (iteration %d/%d)', self.iteration + 1, self.max_iterations))
        self.intent_raw = self:_merge_correction(correction)
        self.state      = states.STATES.REVISING
        self.iteration  = self.iteration + 1
        return { stage = 'generate', system_context = self:build_generate_system_context(), prompt = self:build_generate_user_message() }
    end
    self.state = states.STATES.REVIEWING
    return { stage = "review", prompt = self:build_review_prompt() }
end


function M:_merge_correction(correction)
    local new_corrections = self.corrections
    table.insert(new_corrections, correction)
    if not self.intent_raw then
        self.intent_raw = self.intent and self.intent.raw or ""
    end
    local revision_parts = {}
    -- Fix #4: Keep full corrections for iterations 1-3 (not 1-2)
    if #new_corrections <= 3 then
        for i, c in ipairs(new_corrections) do
            table.insert(revision_parts, string.format("Correction #%d:\n%s", i, c))
        end
    else
        -- Summarize ALL earlier corrections into a single accumulated paragraph
        local accumulated = {}
        for i = 1, #new_corrections - 1 do
            table.insert(accumulated, parsers.summarize_correction(new_corrections[i]))
        end
        table.insert(revision_parts, "Accumulated reviewer notes (iterations 1-" .. (#new_corrections - 1) .. "):\n" .. table.concat(accumulated, ". ") .. ".")
        -- Keep only the latest correction in full
        table.insert(revision_parts, string.format("Correction #%d (latest):\n%s", #new_corrections, new_corrections[#new_corrections]))
    end
    return self.intent_raw
        .. "\n\n<REVISION iteration=\"" .. self.iteration .. "\">\n"
        .. "Previous attempt failed. Reviewer notes:\n"
        .. table.concat(revision_parts, "\n\n") .. "\n"
        .. "Adjust PAYLOAD accordingly. Keep GOAL and SUCCESS_CRITERIA.\n"
        .. "</REVISION>"
end


function M:reset()
    self.state        = states.STATES.IDLE
    self.task         = nil
    self.intent       = nil
    self.intent_raw   = nil
    self.payload      = nil
    self.last_result  = nil
    self.review       = nil
    self.corrections  = {}
    self.iteration    = 0
    self.validation_retries = 0
    self.tool_failures = {}
    self.partial_passed_criteria = {}
    self.budget_retry_done = false
    self.pending_intent_validation = false
end
-- Fix #5: State persistence
function M:save_state()
    local json = require("JSON")
    local os_mod = require("os")
    os_mod.execute(string.format("mkdir -p '%s/.e-va-conf'", self.ctx.config.PROJECT_ROOT))
    local state_file = string.format("%s/.e-va-conf/.multi_stage_state_%s.json", self.ctx.config.PROJECT_ROOT, self.agent_name)
    local snap = {
        task = self.task or "",
        intent_tool = self.intent and self.intent.TOOL or "",
        intent_goal = self.intent and self.intent.GOAL or "",
        intent_raw = self.intent_raw or "",
        payload = self.payload or "",
        last_result_summary = "",
        state = self.state or "",
        iteration = self.iteration or 0,
        total_tokens_used = self.total_tokens_used or 0,
        file_path = self.file_path or "",
        tool_failures = self.tool_failures or {},
        partial_passed_criteria = self.partial_passed_criteria or {},
    }
    if self.last_result then
        local lr = tostring(self.last_result)
        snap.last_result_summary = lr:sub(1, 1000)
    end
    local encoded = json:encode(snap)
    local f = io.open(state_file, "w")
    if f then f:write(encoded); f:close() end
end
function M:load_state()
    local json = require("JSON")
    local state_file = string.format("%s/.e-va-conf/.multi_stage_state_%s.json", self.ctx.config.PROJECT_ROOT, self.agent_name)
    local f = io.open(state_file, "r")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    local ok, snap = pcall(function() return json:decode(data) end)
    if not ok then return false end
    if snap.task then self.task = snap.task end
    if snap.intent_raw then self.intent_raw = snap.intent_raw end
    if snap.payload then self.payload = snap.payload end
    if snap.state then self.state = snap.state end
    if snap.iteration then self.iteration = snap.iteration end
    if snap.total_tokens_used then self.total_tokens_used = snap.total_tokens_used end
    if snap.file_path then self.file_path = snap.file_path end
    if snap.tool_failures then self.tool_failures = snap.tool_failures end
    if snap.partial_passed_criteria then self.partial_passed_criteria = snap.partial_passed_criteria end
    return true
end
return M