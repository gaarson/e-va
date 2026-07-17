local M = {}
local utils    = require("utils")
local registry = require("tool_registry")
local logger   = require("logger")

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

------------------------------------------------------------------------

-- Tool-Specific Prompt Fragments

------------------------------------------------------------------------

M.TOOL_GENERATE_HINTS = {
    patch = [[
PAYLOAD FORMAT FOR `patch`:
Output ONLY SEARCH/REPLACE diff blocks. DO NOT include the file path.

The file path is handled automatically by the system.
<<<<<<< SEARCH
<exact lines from the file, 2-4 lines of UNCHANGED context>
<lines to replace>
<more unchanged context>
=======
<exact same unchanged context lines>
<new replacement lines>
<same unchanged context lines>
>>>>>>> REPLACE

RULES:
- SEARCH block MUST match the actual file content EXACTLY (character-for-character).
- Include 2-4 lines of unchanged context around the change to make the match unique.
- The unchanged context lines must appear IDENTICALLY in both SEARCH and REPLACE blocks.
- Do NOT wrap in code fences. Do NOT add explanations.
- Do NOT include the file path in your output.
- If multiple changes in the same file, output multiple SEARCH/REPLACE blocks sequentially.
]], create_file = [[
PAYLOAD FORMAT FOR `create_file`:
Output ONLY the complete file content. DO NOT include the file path.
The file path is handled automatically by the system.
RULES:
- Output ONLY the file content, starting from the first line.
- No wrappers, no explanations, no markdown fences.
- Content must be syntactically valid for the target language.
- If the file already exists, it will be overwritten (backup created if configured).
- Directories will be auto-created if they don't exist.
- Do NOT include the file path in your output.
]], delegate_plan = [[
PAYLOAD FORMAT FOR `delegate_plan`:

{
  "plan": [
    {"file": "path/to/file1.ext", "instruction": "Atomic, verifiable task description"},
    {"file": "path/to/file2.ext", "instruction": "Another atomic task"}
  ],
  "memo": "Rich context for the receiving agent. Include: background, constraints, conventions, known issues, dependencies."
}

RULES:
- Valid JSON only. No markdown, no code fences, no explanations.
- "plan" is REQUIRED: array of objects with "file" and "instruction" keys.
- "memo" is HIGHLY RECOMMENDED: this is the primary context carrier to the next agent.
- Each instruction must be ATOMIC (one specific change) and VERIFIABLE (can be checked as done/not-done).
- File paths must be concrete (no placeholders like "TODO" or "path/to/file").
- If the memo is empty or too brief, the receiving agent will lack critical context.

]],

}


M.TOOL_REVIEW_CHECKS = {
    patch = [[
TOOL-SPECIFIC REVIEW CHECKS FOR `patch`:
- [ ] Does every SEARCH block contain 2-4 lines of unchanged context?
- [ ] Would the SEARCH blocks match the actual file content exactly?
- [ ] Are there zero-op patches (SEARCH == REPLACE)?
- [ ] If multiple patches, is the application order correct?
- [ ] Did the execution result confirm successful patching (no [PATCH FAILED])?
- [ ] Are the changed lines syntactically valid for the target language?
- [ ] If revision was requested, were the reviewer's corrections applied correctly?
- [ ] Does the <file_content_after_patch> block reflect the intended changes?
- [ ] IF <file_content_after_patch> IS PRESENT IN THE EXECUTION RESULT:
     Compare the file content AFTER patching against the intended changes.
     Verify that the REPLACE blocks were actually applied correctly in the resulting file.
     Check that no unintended side effects occurred (e.g., broken indentation, missing lines).
- [ ] IF --- UNIFIED DIFF --- IS PRESENT IN THE EXECUTION RESULT:
     Verify the diff accurately represents the changes made.
     Confirm that removed lines (-) and added lines (+) match the intended modification.
]], create_file = [[

TOOL-SPECIFIC REVIEW CHECKS FOR `create_file`:

- [ ] Was the file created at the correct path?
- [ ] Is the content complete (not truncated)?
- [ ] Does the content follow project conventions?
- [ ] Are there no syntax errors in the created file?
- [ ] If revision was requested, were the reviewer's corrections applied correctly?

]], delegate_plan = [[

TOOL-SPECIFIC REVIEW CHECKS FOR `delegate_plan`:

- [ ] Was the JSON payload valid and parseable?
- [ ] Does "plan" contain an array of {file, instruction} objects?
- [ ] Is "memo" present and sufficiently detailed for the receiving agent?
- [ ] Are all file paths concrete (not placeholders)?
- [ ] Are instructions atomic and verifiable?
- [ ] Does the memo include: background context, constraints, conventions, known issues?
- [ ] If revision was requested, were JSON syntax and content issues fixed?

]],
}

-- Helpers
------------------------------------------------------------------------
--- Sanitize LLM-generated payload: strip markdown fences, thinking tags,
--- common preamble phrases, and leading/trailing whitespace.
--- IMPROVED: Only strip balanced thinking tags, protect code comments, log significant removals.
local function sanitize_payload(raw)
    if not raw then return "" end
    local s = utils.trim(raw)
    local original_len = #s
    local removed_chars = 0
    -- Strip markdown code fences (```lang ... ```)
    s = s:gsub("^%s*```[%w%-]*\n?", "")
    s = s:gsub("\n?```%s*$", "")
    -- Strip BALANCED thinking tags only (protects unbalanced/code comments)
    -- Match <thinking>...</thinking> or <think> ...  with proper balancing
    local function strip_balanced_tags(text, open_tag, close_tag)
        local result = text
        local found = true
        while found do
            local start_pos = result:find(open_tag, 1, true)
            if start_pos then
                local end_pos = result:find(close_tag, start_pos + #open_tag, true)
                if end_pos then
                    local removed = result:sub(start_pos, end_pos + #close_tag - 1)
                    removed_chars = removed_chars + #removed
                    result = result:sub(1, start_pos - 1) .. result:sub(end_pos + #close_tag)
                else
                    found = false  -- Unbalanced tag, leave it alone
                end
            else
                found = false
            end
        end
        return result
    end
    s = strip_balanced_tags(s, "<thinking>", "</thinking>")
    s = strip_balanced_tags(s, "<think>", "<//think>")
    -- Strip HTML comments (balanced only)
    s = strip_balanced_tags(s, "<!--", "-->")
    -- Strip common preamble phrases (case-insensitive)
    local preambles = {
        "^here is the payload%s*:?",
        "^here is the command%s*:?",
        "^here is the content%s*:?",
        "^command%s*:?",
        "^payload%s*:?",
        "^content%s*:?",
        "^the payload is%s*:?",
        "^the command is%s*:?",
    }
    for _, pat in ipairs(preambles) do
        s = s:gsub(pat, "", 1)
    end
    -- Strip ||| COMMAND ||| ... ||| END_COMMAND ||| wrappers
    s = s:gsub("^%s*|||%s*COMMAND%s*|||%s*\n?", "")
    s = s:gsub("\n?|||%s*END_COMMAND%s*|||%s*$", "")
    local final_s = utils.trim(s)
    -- Log significant content removal for debugging
    if removed_chars > 100 then
        logger.info(string.format("[SANITIZE] Removed %d chars of thinking/tags from payload (%.1f%% of original)", 
            removed_chars, (removed_chars / original_len) * 100))
    end
    return final_s
end
--- Безопасный шаблонизатор: заменяет {key} на значения из vars.
--- Не интерпретирует '%' в значениях, не ломается на магических символах.
local function render(template, vars)
    return (template:gsub("{([%w_]+)}", function(key)
        local v = vars[key]
        if v == nil then return "{" .. key .. "}" end
        return tostring(v)
    end))
end

--- Robust line-by-line field extractor for <INTENT>/<REVIEW> blocks.
--- Splits the block into lines, iterates through them, and matches lines
--- starting with 'FIELDNAME:' (case-insensitive prefix match). Continuation
--- lines (lines not matching 'WORD:') are accumulated into the current field.
--- Handles arbitrary field order, blank lines, and trailing content.
--- Validate payload content based on tool type BEFORE execution.
--- Returns (true, nil) if valid, or (false, error_message) if invalid.
local function validate_payload(tool_name, payload)
    if not payload or utils.trim(payload) == "" then
        return false, "Payload is empty."
    end
    if tool_name == "delegate_plan" then
        -- Must be valid JSON with "plan" and "memo" fields
        local json = require("JSON")
        local ok, data = pcall(json.decode, payload)
        if not ok then
            return false, "delegate_plan payload is not valid JSON: " .. tostring(data)
        end
        if not data.plan or type(data.plan) ~= "table" then
            return false, "delegate_plan payload missing 'plan' array."
        end
        if not data.memo or utils.trim(data.memo) == "" then
            return false, "delegate_plan payload missing or empty 'memo' field."
        end
    elseif tool_name == "patch" then
        -- Must contain at least one SEARCH/REPLACE block
        if not payload:find("<<<<<<< SEARCH") then
            return false, tool_name .. " payload must contain at least one SEARCH/REPLACE block."
        end
        if not payload:find(">>>>>>> REPLACE") then
            return false, tool_name .. " payload has SEARCH block but no closing REPLACE marker."
        end
    elseif tool_name == "create_file" then
        -- First line must be a file path (non-empty)
        local first_line = payload:match("^[^\r\n]+")
        if not first_line or utils.trim(first_line) == "" then
            return false, "create_file payload must start with a file path."
        end
    end
    return true, nil
end
local function extract_field(block, name)
    if not block or not name then return "" end
    local target_upper = name:upper()
    local lines = {}
    for line in block:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    local results = {}
    local current_key = nil
    local current_value = {}
    for i = 1, #lines do
        local line = lines[i]
        -- Check if this line starts a new field: WORD: (possibly with leading whitespace)
        local field_name, field_value = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*:%s*(.*)")
        if field_name then
            -- Save previous field
            if current_key then
                results[current_key:upper()] = table.concat(current_value, "\n")
            end
            current_key = field_name:upper()
            current_value = { field_value }
        else
            -- Continuation line
            if current_key then
                table.insert(current_value, line)
            end
        end
    end
    -- Save last field
    if current_key then
        results[current_key:upper()] = table.concat(current_value, "\n")
    end
    local val = results[target_upper]
    if val == nil then return "" end
    return utils.trim(val)
end

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
        total_tokens_used = 0,
        max_tokens_per_task = opts.max_tokens_per_task or 32000,
        budget_mode       = opts.budget_mode or "adaptive",  -- 'adaptive', 'fixed', 'aggressive'
        file_path         = opts.file_path or nil,  -- Pre-known file path for patch/create_file (selective multi-stage)
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
        GOAL             = extract_field(block, "GOAL"),
        TOOL             = extract_field(block, "TOOL"),
        FILE_PATH        = extract_field(block, "FILE_PATH"),
        PAYLOAD_HINT     = extract_field(block, "PAYLOAD_HINT"),
        SUCCESS_CRITERIA = extract_field(block, "SUCCESS_CRITERIA"),
        raw              = utils.trim(block),
    }

    -- TOOL — только первое слово
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
        correction = extract_field(block, "CORRECTION")
        if correction == "" then
            return nil, "VERDICT is REVISE but CORRECTION block is empty."
        end
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

    return render(self.prompts.intent, {
        task_description     = task or "",
        project_context      = project_context or "",
        available_tools_list = table.concat(tools_list, "\n"),
    })
end


function M:build_generate_prompt()
    local tool_name = self.intent and self.intent.TOOL or ""
    local tool_hint = M.TOOL_GENERATE_HINTS[tool_name] or ""
    local hint_block = ""

    if tool_hint ~= "" then
        -- NOTE: TOOL_GENERATE_HINTS.patch already instructs the LLM to never include
        -- the file path. The executor handles file path injection automatically.
        -- No dynamic override needed.
        hint_block = "\n\n" .. tool_hint
    end

    return render(self.prompts.generate, {
        intent_text = self.intent_raw or "",
        tool_specific_hint = hint_block,
    })
end

function M:build_review_prompt()
    local tool_name = self.intent and self.intent.TOOL or ""
    local tool_checks = M.TOOL_REVIEW_CHECKS[tool_name] or ""
    local checks_block = ""
    if tool_checks ~= "" then
        checks_block = "\n\n" .. tool_checks
    end
    return render(self.prompts.review, {
        intent_text      = self.intent_raw or "",
        payload_text     = self.payload or "",
        execution_output = self.last_result or "",
        tool_specific_checks = checks_block,
    })
end

------------------------------------------------------------------------
-- Public API: Start with pre-filled intent (skip INTENT phase)
------------------------------------------------------------------------

-- ============================================================================
-- COMPLEXITY HEURISTIC: Estimate task complexity to decide if review is needed
-- ============================================================================
local function estimate_complexity(tool_name, payload_hint, file_path)
    -- Simple operations: non-code files with small payloads
    local simple_extensions = { ".md", ".txt", ".json", ".cfg", ".yaml", ".toml", ".ini", ".env", ".lock", ".gitignore" }
    local is_simple_ext = false
    if file_path then
        for _, ext in ipairs(simple_extensions) do
            if file_path:match(ext .. "$") then
                is_simple_ext = true
                break
            end
        end
    end
    -- Check payload hint for simplicity indicators
    local hint_lower = (payload_hint or ""):lower()
    local is_small_payload = hint_lower:match("small") or hint_lower:match("simple") or hint_lower:match("single") or hint_lower:match("short") or hint_lower:match("<500") or hint_lower:match("<1000")
    -- If it's a simple file type AND payload hint suggests small content, skip review
    if is_simple_ext and is_small_payload then
        return "simple"
    end
    -- For create_file with simple extensions, also consider simple
    if tool_name == "create_file" and is_simple_ext then
        return "simple"
    end
    return "complex"
end
function M:start_task_with_intent(task, project_context, tool_name, payload_hint, success_criteria, file_path)
    self:reset()
    -- Store pre-known file_path for selective multi-stage (patch/create_file)
    if file_path and file_path ~= "" then
        self.file_path = utils.trim(file_path)
    end
    -- Validate tool_name exists in registry and is allowed for the agent
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
    -- COMPLEXITY HEURISTIC: Skip review cycle for simple operations
    -- Optimization rationale: Simple file operations (config files, docs, small data files)
    -- don't benefit from the review cycle and waste tokens/time. By detecting these
    -- upfront, we can set max_iterations=1 to bypass the review phase entirely.
    local complexity = estimate_complexity(tool_name, payload_hint, file_path)
    if complexity == "simple" then
        self.max_iterations = 1  -- Skip review cycle for simple operations
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
    self.state      = M.STATES.INTENT_READY
    self.iteration  = 1
    return { stage = "generate", prompt = self:build_generate_prompt() }
end


function M:start_task(task, project_context)
    self:reset()
    self.task      = task
    self.state     = M.STATES.INTENT_DRAFT
    self.iteration = 1
    return { stage = "intent", prompt = self:build_intent_prompt(task, project_context) }
end
-- Adaptive token budget calculation
function M:calculate_token_budget()
    local mode = self.budget_mode
    local ctx = self.ctx
    local config = ctx and ctx.config
    if mode == "fixed" then
        -- Legacy behavior: fixed 32K budget
        return self.max_tokens_per_task
    elseif mode == "aggressive" then
        -- 80% of available context
        if config and config.LIMITS then
            local available = config.LIMITS.MAX_CONTEXT - config.LIMITS.RESERVED_OUTPUT - config.LIMITS.SYSTEM_PROMPT_ESTIMATE
            return math.floor(available * 0.8)
        end
        return self.max_tokens_per_task
    else
        -- 'adaptive' (default): 60% for current task, 40% reserved for subsequent turns
        if config and config.LIMITS then
            local available = config.LIMITS.MAX_CONTEXT - config.LIMITS.RESERVED_OUTPUT - config.LIMITS.SYSTEM_PROMPT_ESTIMATE
            return math.floor(available * 0.6)
        end
        return self.max_tokens_per_task
    end
end
function M:feed_response(llm_response)
    if self.state == M.STATES.INTENT_DRAFT then
        local intent, err = self:parse_intent(llm_response)
        if not intent then
            return { stage = "error", message = "Intent parse failed: " .. err }
        end
        self.intent     = intent
        self.intent_raw = intent.raw
        -- Capture file_path from intent for patch/create_file tools
        if (intent.TOOL == "patch" or intent.TOOL == "create_file") and intent.FILE_PATH and utils.trim(intent.FILE_PATH) ~= "" then
            self.file_path = utils.trim(intent.FILE_PATH)
        end
        self.state      = M.STATES.INTENT_READY
        return { stage = "generate", prompt = self:build_generate_prompt() }
    end
    if self.state == M.STATES.INTENT_READY or self.state == M.STATES.REVISING then
        self.payload = sanitize_payload(llm_response)
        -- Pre-execution validation
        local valid, err_msg = validate_payload(self.intent.TOOL, self.payload)
        if not valid then
            logger.warn(string.format("[MULTI-STAGE] Payload validation failed for tool '%s': %s", self.intent.TOOL, err_msg))
            self.state = M.STATES.ERROR
            return { stage = "error", message = "Payload validation failed: " .. err_msg }
        end
        self.state   = M.STATES.COMMAND_READY
        -- If file_path is pre-known for patch/create_file tools, prepend it to payload for the tool handler
        local effective_payload = self.payload
        if (self.intent.TOOL == "patch" or self.intent.TOOL == "create_file") and self.file_path and self.file_path ~= "" then
            effective_payload = self.file_path .. "\n" .. self.payload
        end
        return { stage = "execute", tool = self.intent.TOOL, payload = effective_payload }
    end
    if self.state == M.STATES.REVIEWING then
        -- ADAPTIVE TOKEN BUDGET CHECK: Force-approve if we've exceeded the calculated budget
        local budget = self:calculate_token_budget()
        if self.total_tokens_used > budget then
            logger.warn(string.format(
                "[MULTI-STAGE] Token budget exceeded (%d/%d, mode=%s). Force-approving to prevent runaway token consumption.",
                self.total_tokens_used, budget, self.budget_mode
            ))
            self.state = M.STATES.APPROVED
            return { stage = "done", result = self.last_result, iterations = self.iteration, forced_approval = true }
        end
        local review, err = self:parse_review(llm_response)
        if not review then
            -- FALLBACK: Try to infer verdict from raw text
            local upper_resp = llm_response:upper()
            local inferred_verdict = nil
            if upper_resp:find("APPROVE") and not upper_resp:find("REVISE") then
                inferred_verdict = "APPROVE"
            elseif upper_resp:find("REVISE") or upper_resp:find("REVISION") or upper_resp:find("FAIL") or upper_resp:find("ERROR") then
                inferred_verdict = "REVISE"
            end
            if inferred_verdict == "APPROVE" then
                logger.warn("[MULTI-STAGE] Review parse failed but APPROVE inferred from response. Auto-approving.")
                self.state = M.STATES.APPROVED
                return { stage = "done", result = self.last_result, iterations = self.iteration }
            elseif inferred_verdict == "REVISE" then
                logger.warn(string.format("[MULTI-STAGE] Review parse failed but REVISE inferred. Using fallback correction: '%s'", err))
                self.review = { verdict = "REVISE", correction = "Reviewer could not be parsed. Correction: " .. err, raw = utils.trim(llm_response) }
            else
                -- Cannot infer anything — auto-APPROVE with warning to avoid infinite loops
                logger.warn(string.format("[MULTI-STAGE] Review parse failed and no verdict inferable. Auto-approving to prevent infinite loop. Error: %s", err))
                self.state = M.STATES.APPROVED
                return { stage = "done", result = self.last_result, iterations = self.iteration }
            end
        else
            self.review = review
        end
        if self.review.verdict == "APPROVE" then
            self.state = M.STATES.APPROVED
            return { stage = "done", result = self.last_result, iterations = self.iteration }
        end
        if self.review.verdict == "REVISE" then
            if self.iteration >= self.max_iterations then
                self.state = M.STATES.ERROR
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
            self.state      = M.STATES.REVISING
            self.iteration  = self.iteration + 1
            return { stage = "generate", prompt = self:build_generate_prompt() }
        end
    end
    return { stage = "error", message = "Unexpected state: " .. self.state }
end
function M:feed_execution_result(output)
  if self.state ~= M.STATES.COMMAND_READY then
      return { stage = "error", message = "Not in COMMAND_READY state." }
  end
  -- Extract output string and signal from result table
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
  -- Build base result string with signal if present
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
      -- Extract file path: use pre-known file_path if available, otherwise extract from payload
      local file_paths_list = {}
      if self.file_path and self.file_path ~= "" then
          file_paths_list[#file_paths_list + 1] = self.file_path
      elseif self.payload then
          local first_line = self.payload:match("^[^\r\n]+")
          if first_line and utils.trim(first_line) ~= "" then
              file_paths_list[#file_paths_list + 1] = utils.trim(first_line)
          end
      end
      -- Append file content from knowledge_base for each path
      for _, fp in ipairs(file_paths_list) do
          -- Normalize path for knowledge_base lookup
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
  self.state       = M.STATES.REVIEWING
  return { stage = "review", prompt = self:build_review_prompt() }
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
--- Summarize a correction to a concise directive (max ~200 chars).
--- Keeps the most actionable part of the reviewer's feedback.
local function summarize_correction(correction)
    local trimmed = utils.trim(correction)
    if #trimmed <= 200 then return trimmed end
    -- Take the first 200 chars and truncate at a sentence boundary if possible
    local sub = trimmed:sub(1, 200)
    local last_period = sub:find("%. ", 180) or sub:find("%.$", 180)
    if last_period then
        return sub:sub(1, last_period) .. "..."
    end
    return sub:sub(1, 197) .. "..."
end
function M:_merge_correction(correction)
    -- Maintain a rolling window of at most 2 corrections.
    -- Older corrections are summarized into an accumulated block.
    local new_corrections = self.corrections
    table.insert(new_corrections, correction)
    local revision_parts = {}
    if #new_corrections <= 2 then
        -- Few corrections: include all raw
        for i, c in ipairs(new_corrections) do
            table.insert(revision_parts, string.format("Correction #%d:\n%s", i, c))
        end
    else
        -- More than 2: summarize all but the last 2
        local accumulated = {}
        for i = 1, #new_corrections - 2 do
            table.insert(accumulated, summarize_correction(new_corrections[i]))
        end
        table.insert(revision_parts, "Accumulated reviewer notes (earlier iterations):\n" .. table.concat(accumulated, "\n\n"))
        -- Last 2 raw
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
You are an Action Architect. Your task is NOT to execute a command, but to PLAN it precisely.

You have been given a task:
<task>
{task_description}
</task>

Project context:
<context>
{project_context}
</context>

Available tools:
<tools>
{available_tools_list}
</tools>

Formulate an intent — a plan for ONE specific command. DO NOT write the command itself. Only plan it.

Response format (strict):

<INTENT>
GOAL: <what we want to achieve, 1-2 sentences>
TOOL: <tool name from the list above>
FILE_PATH: <exact file path for patch/create_file tools, empty if not applicable>
PAYLOAD_HINT: <brief description of the command contents>
SUCCESS_CRITERIA: <concrete, verifiable success criteria>
</INTENT>

TOOL SELECTION GUIDELINES:
- `patch`: Use when modifying an existing file. You MUST know the exact file content. Include sufficient SEARCH context.
- `create_file`: Use when creating a brand-new file. Provide complete, valid file content.
- `delegate_plan`: Use to delegate work to another agent (CODER). Provide a structured plan with memo context.

Rules:
1. GOAL — one specific goal, concrete.
2. TOOL — must be from the list above. If none fit, use TOOL: NONE. Consider the guidelines above.
3. FILE_PATH — for `patch` and `create_file` tools, specify the EXACT file path. Leave empty for other tools.
4. PAYLOAD_HINT — enough detail to guide generation, but NOT the actual payload. Describe the structure and key elements.
5. SUCCESS_CRITERIA — verifiable assertions, not vague statements like "everything works".
6. Do NOT add anything outside the <INTENT>...</INTENT> tags.
7. If the task is large, describe ONLY the FIRST step.
8. If the task description includes a pre-existing command or context from a previous turn, USE IT.
   Do not discard valuable context. Incorporate file paths, findings, and decisions already made.
]]

M.DEFAULT_GENERATE_PROMPT = [[
You are a Command Generator. Convert the intent into a READY-TO-USE payload.

Intent:
{intent_text}

CRITICAL RULE:
Your output will be INSERTED DIRECTLY AS THE TOOL'S PAYLOAD.
No parsing. No wrapping. No markdown. No explanations.

FORBIDDEN:
✗ Writing "Here is my command:" or "Here is the content:"
✗ Wrapping in code fences (``` ... ```)
✗ Adding comments before or after the payload
✗ Using ||| COMMAND ||| markers

REQUIRED:
✓ Output ONLY the raw payload
✓ Follow the PAYLOAD_HINT from the intent
✓ If there is a <REVISION> block, incorporate the reviewer's corrections EXACTLY.

   Read the correction carefully. Apply ONLY what the reviewer asked to change.

   Do NOT rewrite the entire payload unless the reviewer explicitly says so.
✓ Adhere to the tool-specific payload format below{tool_specific_hint}

Start immediately with the first line of the payload. End immediately after the last line.
]]

M.DEFAULT_REVIEW_PROMPT = [[
You are a Result Reviewer. Compare the execution result against the original intent.

Original intent:
{intent_text}

Generated payload:
<payload>
{payload_text}
</payload>

Execution result:
<result>
{execution_output}
</result>

Evaluate each SUCCESS_CRITERIA item individually.

Response format (strict):

<REVIEW>
VERDICT: APPROVE | REVISE

CHECKLIST:
- [ ] <criteria 1>: PASS/FAIL — <commentary>
- [ ] <criteria 2>: PASS/FAIL — <commentary>

CORRECTION:
<what specifically is wrong>
<how to fix it — direction, not a ready-made payload>
</REVIEW>

{tool_specific_checks}

Rules:
1. APPROVE — ONLY if ALL criteria AND all tool-specific checks are PASS.
2. REVISE — if AT LEAST ONE criterion or tool-specific check is FAIL.
3. In CORRECTION, be SPECIFIC: quote the exact lines that are wrong and describe the fix.
   Do NOT write a ready-made payload. Give directional guidance.
4. If the payload has syntax errors (JSON, Lua, C, etc.), flag them explicitly.
5. If the execution result shows partial success, approve only the successful parts and revise the rest.
6. Do NOT add anything outside the <REVIEW>...</REVIEW> tags.
]]

return M