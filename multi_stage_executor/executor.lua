
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

    if verdict ~= "APPROVE" and verdict ~= "REVISE" then

        return nil, "Invalid VERDICT: '" .. verdict .. "'. Expected APPROVE or REVISE."

    end

    local correction = nil

    if verdict == "REVISE" then

        correction = parsers.extract_field(block, "CORRECTION")

        if correction == "" then

            return nil, "VERDICT is REVISE but CORRECTION block is empty."

        end

    end

    return { verdict = verdict, correction = correction, raw = utils.trim(block) }, nil

end


function M:build_intent_prompt(task, project_context)

    local tools_list = {}

    for name, tool in pairs(registry.tools) do

        if registry.is_tool_allowed(self.ctx.config.AGENTS[self.agent_name], name) then

            tools_list[#tools_list + 1] = string.format("- %s: %s", name, tool.desc or "(no description)")

        end

    end

    table.sort(tools_list)

    return parsers.render(self.prompts.intent, {

        task_description     = task or "",

        project_context      = project_context or "",

        available_tools_list = table.concat(tools_list, "\n"),

    })

end


function M:build_generate_prompt()

    local tool_name = self.intent and self.intent.TOOL or ""

    local tool_hint = states.TOOL_GENERATE_HINTS[tool_name] or ""

    local hint_block = ""

    if tool_hint ~= "" then

        hint_block = "\n\n" .. tool_hint

    end

    return parsers.render(self.prompts.generate, {

        intent_text = self.intent_raw or "",

        tool_specific_hint = hint_block,

    })

end


function M:build_review_prompt()

    local tool_name = self.intent and self.intent.TOOL or ""

    local tool_checks = states.TOOL_REVIEW_CHECKS[tool_name] or ""

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

    if self.state == states.STATES.INTENT_DRAFT then

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

        self.payload = parsers.sanitize_payload(llm_response)

        local valid, err_msg = parsers.validate_payload(self.intent.TOOL, self.payload)

        if not valid then

            logger.warn(string.format("[MULTI-STAGE] Payload validation failed for tool '%s': %s", self.intent.TOOL, err_msg))

            self.state = states.STATES.ERROR

            return { stage = "error", message = "Payload validation failed: " .. err_msg }

        end

        self.state   = states.STATES.COMMAND_READY

        local effective_payload = self.payload

        if (self.intent.TOOL == "patch" or self.intent.TOOL == "create_file") and self.file_path and self.file_path ~= "" then

            effective_payload = self.file_path .. "\n" .. self.payload

        end

        return { stage = "execute", tool = self.intent.TOOL, payload = effective_payload }

    end

    if self.state == states.STATES.REVIEWING then

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

            if upper_resp:find("APPROVE") and not upper_resp:find("REVISE") then

                inferred_verdict = "APPROVE"

            elseif upper_resp:find("REVISE") or upper_resp:find("REVISION") or upper_resp:find("FAIL") or upper_resp:find("ERROR") then

                inferred_verdict = "REVISE"

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

    if tool_name == "patch" then

        local file_paths_list = {}

        if self.file_path and self.file_path ~= "" then

            file_paths_list[#file_paths_list + 1] = self.file_path

        elseif self.payload then

            local first_line = self.payload:match("^[^\r\n]+")

            if first_line and utils.trim(first_line) ~= "" then

                file_paths_list[#file_paths_list + 1] = utils.trim(first_line)

            end

        end

        for _, fp in ipairs(file_paths_list) do

            local normalized = fp

            if not fp:match("^/") then

                normalized = utils.normalize_path(self.ctx.config.PROJECT_ROOT, fp)

            end

            local content = self.ctx.knowledge_base[normalized]

            if content then

                enriched_result = enriched_result .. string.format("\n\n<file_content_after_patch path=\"%s\">\n%s\n</file_content_after_patch>", normalized, content)

            else

                enriched_result = enriched_result .. string.format("\n\n[file_content_after_patch path=\"%s\"] File not found in knowledge_base.", normalized)

            end

        end

    end

    self.last_result = enriched_result

    self.state       = states.STATES.REVIEWING

    return { stage = "review", prompt = self:build_review_prompt() }

end


function M:_merge_correction(correction)

    local new_corrections = self.corrections

    table.insert(new_corrections, correction)

    local revision_parts = {}

    if #new_corrections <= 2 then

        for i, c in ipairs(new_corrections) do

            table.insert(revision_parts, string.format("Correction #%d:\n%s", i, c))

        end

    else

        local accumulated = {}

        for i = 1, #new_corrections - 2 do

            table.insert(accumulated, parsers.summarize_correction(new_corrections[i]))

        end

        table.insert(revision_parts, "Accumulated reviewer notes (earlier iterations):\n" .. table.concat(accumulated, "\n\n"))

        for i = #new_corrections - 1, #new_corrections do

            table.insert(revision_parts, string.format("Correction #%d:\n%s", i, new_corrections[i]))

        end

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

end


return M

