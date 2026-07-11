local M = {}
local utils    = require("utils")
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


------------------------------------------------------------------------

-- Tool-Specific Prompt Fragments

------------------------------------------------------------------------

M.TOOL_GENERATE_HINTS = {

    patch = [[

PAYLOAD FORMAT FOR `patch`:

Line 1: FILE PATH (relative or absolute)
Then: SEARCH/REPLACE diff blocks.

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
- First line must be the file path, followed by the diff blocks.
- If multiple changes in the same file, output multiple SEARCH/REPLACE blocks sequentially.

]],

    create_file = [[

PAYLOAD FORMAT FOR `create_file`:

Line 1: FILE PATH (relative or absolute)
Line 2+: Complete file content.

RULES:
- First line must be the file path.
- Second line onwards: the COMPLETE file content.
- No wrappers, no explanations, no markdown fences.
- Content must be syntactically valid for the target language.
- If the file already exists, it will be overwritten (backup created if configured).
- Directories will be auto-created if they don't exist.

]],

    batch_patch = [[

PAYLOAD FORMAT FOR `batch_patch`:

file_path_1
<<<<<<< SEARCH
<context + old code>
=======
<context + new code>
>>>>>>> REPLACE
---FILE---
file_path_2
<<<<<<< SEARCH
<context + old code>
=======
<context + new code>
>>>>>>> REPLACE

RULES:
- Each file starts with its path on a single line.
- Followed by one or more SEARCH/REPLACE blocks.
- Separate files with ---FILE--- on its own line.
- Every SEARCH block needs 2-4 lines of unchanged context.
- Order matters if patches are interdependent.
- No JSON wrapping. Raw text format only.

]],

    delegate_plan = [[

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

]],

    create_file = [[

TOOL-SPECIFIC REVIEW CHECKS FOR `create_file`:

- [ ] Was the file created at the correct path?
- [ ] Is the content complete (not truncated)?
- [ ] Does the content follow project conventions?
- [ ] Are there no syntax errors in the created file?
- [ ] If revision was requested, were the reviewer's corrections applied correctly?

]],

    batch_patch = [[

TOOL-SPECIFIC REVIEW CHECKS FOR `batch_patch`:

- [ ] Was the format valid (file paths, ---FILE--- separators, SEARCH/REPLACE blocks)?
- [ ] Did ALL patches apply successfully (no partial failures)?
- [ ] Were patches applied in the correct dependency order?
- [ ] Does every SEARCH block have sufficient context?
- [ ] If revision was requested, were only the failed patches corrected?

]],

    delegate_plan = [[

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
local function sanitize_payload(raw)
    if not raw then return "" end
    local s = utils.trim(raw)
    -- Strip markdown code fences (```lang ... ```)
    s = s:gsub("^%s*```[%w%-]*\n?", "")
    s = s:gsub("\n?```%s*$", "")
    -- Strip <think> ... </thinking> or <thinking> ... </thinking> blocks
    s = s:gsub("<%!%-%-.*?%-%->", "")  -- HTML comments just in case
    s = s:gsub("<thinking>.-</thinking>", "")
    s = s:gsub("</thinking>.-<thinking>", "")
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
    return utils.trim(s)
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
        local field_match = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*:%s*(.*)")
        if field_match then
            -- Save previous field
            if current_key then
                results[current_key:upper()] = table.concat(current_value, "\n")
            end
            current_key = field_match:upper()
            current_value = { field_match }
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
-- Public API
------------------------------------------------------------------------


------------------------------------------------------------------------

-- Public API: Start with pre-filled intent (skip INTENT phase)

------------------------------------------------------------------------

function M:start_task_with_intent(task, project_context, tool_name, payload_hint, success_criteria)

    self:reset()

    self.task      = task

    self.intent    = {

        GOAL             = task or "",

        TOOL             = tool_name or "",

        PAYLOAD_HINT     = payload_hint or "",

        SUCCESS_CRITERIA = success_criteria or "",

        raw              = string.format("GOAL: %s\nTOOL: %s\nPAYLOAD_HINT: %s\nSUCCESS_CRITERIA: %s",

            task or "", tool_name or "", payload_hint or "", success_criteria or ""),

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
        self.payload = sanitize_payload(llm_response)
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
                message = string.format(
                    "Failed to satisfy intent after %d iterations. Last correction: %s",
                    self.iteration, review.correction
                ),
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
    self.last_result = (output == nil or output == "") and "<empty output>" or tostring(output)
    self.state       = M.STATES.REVIEWING
    return { stage = "review", prompt = self:build_review_prompt() }
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
--- Sanitize LLM-generated payload: strip markdown fences, thinking tags,
--- common preamble phrases, and leading/trailing whitespace.
local function sanitize_payload(raw)
    if not raw then return "" end
    local s = utils.trim(raw)
    -- Remove markdown code fences (```lang ... ```)
    s = s:gsub("^%s*```[%w_-]*\n?", "")
    s = s:gsub("\n?```%s*$", "")
    -- Remove <think> ... </thinking> or <thinking> ... </thinking> blocks
    s = s:gsub("<!%-%-.*?%-%->", "")  -- HTML comments just in case
    s = (s:gsub("<thinking>.-</thinking>", ""):gsub("</thinking>", ""):gsub("<thinking>", ""))
    s = (s:gsub("<think>.-</thinking>", ""):gsub("</thinking>", ""):gsub("", ""))
    -- Remove common preamble phrases (case-insensitive)
    local preambles = {
        "^here is the payload%s*:?",
        "^here is the content%s*:?",
        "^here is my command%s*:?",
        "^command%s*:?",
        "^payload%s*:?",
        "^output%s*:?",
        "^result%s*:?",
    }
    for _, pat in ipairs(preambles) do
        s = s:gsub(pat, "", 1)
    end
    return utils.trim(s)
end
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
PAYLOAD_HINT: <brief description of the command contents>
SUCCESS_CRITERIA: <concrete, verifiable success criteria>
</INTENT>

TOOL SELECTION GUIDELINES:
- `patch`: Use when modifying an existing file. You MUST know the exact file content. Include sufficient SEARCH context.
- `create_file`: Use when creating a brand-new file. Provide complete, valid file content.
- `batch_patch`: Use when modifying multiple files in one atomic operation. Requires JSON format.
- `delegate_plan`: Use to delegate work to another agent (CODER). Provide a structured plan with memo context.

Rules:
1. GOAL — one specific goal, concrete.
2. TOOL — must be from the list above. If none fit, use TOOL: NONE. Consider the guidelines above.
3. PAYLOAD_HINT — enough detail to guide generation, but NOT the actual payload. Describe the structure and key elements.
4. SUCCESS_CRITERIA — verifiable assertions, not vague statements like "everything works".
5. Do NOT add anything outside the <INTENT>...</INTENT> tags.
6. If the task is large, describe ONLY the FIRST step.
7. If the task description includes a pre-existing command or context from a previous turn, USE IT.
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