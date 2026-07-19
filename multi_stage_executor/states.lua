
local M = {}


M.STATES = {
    IDLE              = "IDLE",
    INTENT_DRAFT      = "INTENT_DRAFT",
    INTENT_READY      = "INTENT_READY",
    COMMAND_READY     = "COMMAND_READY",
    REVIEWING         = "REVIEWING",
    APPROVED          = "APPROVED",
    PARTIAL           = "PARTIAL",
    REVISING          = "REVISING",
    COMPLETED         = "COMPLETED",
    ERROR             = "ERROR",
}


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
- [ ] IF USING PARTIAL VERDICT: List which specific SEARCH/REPLACE blocks passed and which failed. Only revise the failed blocks.
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


return M
