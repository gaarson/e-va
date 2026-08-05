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


function M:build_generate_prompt()
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
    -- Fix #6: Build feedback block after 2+ failures on same tool
    local feedback_block = ""
    if self.tool_failures and self.tool_failures[tool_name] and self.tool_failures[tool_name] >= 2 then
        feedback_block = "\n\n<FEEDBACK>\nThis tool ('" .. tool_name .. "') has failed " .. self.tool_failures[tool_name] .. " times previously.\nReview past corrections carefully and ensure the payload addresses ALL previous issues.\n</FEEDBACK>"
    end
    return parsers.render(self.prompts.generate, {
        intent_text = self.intent_raw or "",
        tool_specific_hint = hint_block,
        feedback_block = feedback_block,
    })
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
        logger.info(string.format("[MULTI-STAGE] Complexity heuristic: '%s' classified as SIMPLE. Skipping review cycle.", tool_name))
    end

    self.task      = task
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

    return { stage = "generate", prompt = self:build_generate_prompt() }

end


function M:start_task(task, project_context)
    self:reset()

    self.task      = task
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
        tokens_used = math.floor(#llm_response / 4)
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
        return { stage = "generate", prompt = self:build_generate_prompt() }
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
            return { stage = "generate", prompt = self:build_generate_prompt() }
        end

        self.state   = states.STATES.COMMAND_READY

        local effective_payload = self.payload

        if (self.intent.TOOL == "patch" or self.intent.TOOL == "create_file") and self.file_path and self.file_path ~= "" then

            effective_payload = self.file_path .. "\n" .. self.payload

        end

        return { stage = "execute", tool = self.intent.TOOL, payload = effective_payload }

    end

    if self.state == states.STATES.REVIEWING then
        self.total_tokens_used = self.total_tokens_used + tokens_used
        local budget = self:calculate_token_budget()

        if self.total_tokens_used > budget then

            logger.warn(string.format(

                "[MULTI-STAGE] Token budget exceeded (%d/%d, mode=%s). Force-approving to prevent runaway token consumption.",

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
            -- (2) Fallback: count occurrences
            if not inferred_verdict then
                local _, approve_count = upper_resp:gsub("APPROVE", "")
                local _, revise_count = upper_resp:gsub("REVISE", "")
                local _, fail_count = upper_resp:gsub("FAIL", "")
                -- Check for conditional approval words after APPROVE
                local has_conditional = upper_resp:find("BUT") or upper_resp:find("HOWEVER") or upper_resp:find("EXCEPT") or upper_resp:find("UNLESS")
                if revise_count > approve_count or fail_count > approve_count then
                    inferred_verdict = "REVISE"
                elseif approve_count > revise_count and not has_conditional then
                    inferred_verdict = "APPROVE"
                elseif has_conditional then
                    inferred_verdict = "REVISE"
                end
            end
            if inferred_verdict == "APPROVE" then
                logger.warn("[MULTI-STAGE] Review parse failed but APPROVE inferred from response. Auto-approving.")
                self.state = states.STATES.APPROVED
                return { stage = "done", result = self.last_result, iterations = self.iteration }
            elseif inferred_verdict == "REVISE" then
                logger.warn(string.format("[MULTI-STAGE] Review parse failed but REVISE inferred. Using fallback correction: '%s'", err))
                self.review = { verdict = "REVISE", correction = "Reviewer could not be parsed. Correction: " .. err, raw = utils.trim(llm_response) }
            else
                logger.warn(string.format("[MULTI-STAGE] Review parse failed and no verdict inferable. Auto-approving to prevent infinite loop. Error: %s", err))
                self.state = states.STATES.APPROVED
                return { stage = "done", result = self.last_result, iterations = self.iteration }
            end
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
            return { stage = "generate", prompt = self:build_generate_prompt() }
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

            return { stage = "generate", prompt = self:build_generate_prompt() }

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
    self.state       = states.STATES.REVIEWING

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
end
-- Fix #5: State persistence
function M:save_state()
    local json = require("JSON")
    local os_mod = require("os")
    os_mod.execute(string.format("mkdir -p '%s/.e-va-conf'", self.ctx.config.PROJECT_ROOT))
    local state_file = self.ctx.config.PROJECT_ROOT .. "/.e-va-conf/.multi_stage_state.json"
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
    local state_file = self.ctx.config.PROJECT_ROOT .. "/.e-va-conf/.multi_stage_state.json"
    local f = io.open(state_file, "r")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    local ok, snap = pcall(json.decode, data)
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