-- Comprehensive tests for multi_stage_executor.lua
-- Run with: ./run_tests.sh tools/__tests__/test_multi_stage_executor.lua
local M = {}
-- Mock dependencies
local mock_utils = {
    trim = function(s)
        if not s then return "" end
        return s:gsub("^%s*(.-)%s*$", "%1")
    end,
    normalize_path = function(root, path)
        return path:gsub("^./", "")
    end
}
local mock_registry = {
    tools = {
        patch = { desc = "Applies diffs" },
        create_file = { desc = "Creates files" },
        delegate_plan = { desc = "Delegates plans" },
        shell = { desc = "Shell commands" },
    },
    is_tool_allowed = function(agent_cfg, tool_name)
        if not agent_cfg or not agent_cfg.allowed_tools then return true end
        for _, t in ipairs(agent_cfg.allowed_tools) do
            if t == tool_name then return true end
        end
        return false
    end
}
local mock_logger = {
    info = function(...) end,
    warn = function(...) end,
    error = function(...) end,
}
-- Install mocks into package.loaded BEFORE requiring multi_stage_executor
package.loaded["utils"] = mock_utils
package.loaded["tool_registry"] = mock_registry
package.loaded["registry"] = mock_registry  -- Also alias for compatibility
package.loaded["logger"] = mock_logger
-- Mock ctx
local function mock_ctx()
    return {
        config = {
            AGENTS = {
                TEST_AGENT = {
                    name = "TEST_AGENT",
                    allowed_tools = {"patch", "create_file", "delegate_plan", "shell"}
                }
            },
            PROJECT_ROOT = "."
        },
        knowledge_base = {},
        history = {},
        add_message = function(self, agent, role, content)
            if not self.history[agent] then self.history[agent] = {} end
            table.insert(self.history[agent], { role = role, content = content })
        end
    }
end
-- Override requires for testing
local old_require = _G.require
package.preload["utils"] = function() return mock_utils end
package.preload["registry"] = function() return mock_registry end
package.preload["logger"] = function() return mock_logger end
local multi_stage = require("multi_stage_executor")
local passed = 0
local failed = 0
local total = 0
local function assert_eq(got, expected, msg)
    total = total + 1
    if got == expected then
        passed = passed + 1
        print(string.format("  ✓ %s", msg))
    else
        failed = failed + 1
        print(string.format("  ✗ %s: expected %q, got %q", msg, expected, got))
    end
end
local function assert_truthy(val, msg)
    total = total + 1
    if val then
        passed = passed + 1
        print(string.format("  ✓ %s", msg))
    else
        failed = failed + 1
        print(string.format("  ✗ %s: expected truthy, got %s", msg, tostring(val)))
    end
end
local function assert_falsy(val, msg)
    total = total + 1
    if not val then
        passed = passed + 1
        print(string.format("  ✓ %s", msg))
    else
        failed = failed + 1
        print(string.format("  ✗ %s: expected falsy, got %q", msg, val))
    end
end
local function assert_contains(haystack, needle, msg)
    total = total + 1
    if haystack and haystack:find(needle, 1, true) then
        passed = passed + 1
        print(string.format("  ✓ %s", msg))
    else
        failed = failed + 1
        print(string.format("  ✗ %s: expected %q to contain %q", msg, haystack, needle))
    end
end
print("\n=== TEST SUITE: multi_stage_executor.lua ===\n")
-- ============================================================================
-- TEST GROUP 1: feed_execution_result correctly extracts output string
-- ============================================================================
print("[GROUP 1] feed_execution_result output extraction")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 1.1: Table result with output field
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    local result = exec:feed_execution_result({ output = "Patch applied successfully", signal = "MUTATION_SUCCESS" })
    assert_eq(result.stage, "review", "Returns review stage")
    assert_truthy(exec.last_result:find("Patch applied successfully"), "Contains output string")
    assert_truthy(exec.last_result:find("MUTATION_SUCCESS"), "Contains signal")
    -- Test 1.2: String result (already a string)
    exec:reset()
    exec.intent = { TOOL = "shell", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    result = exec:feed_execution_result("Command output here")
    assert_eq(result.stage, "review", "Returns review stage for string input")
    assert_truthy(exec.last_result:find("Command output here"), "Contains string output")
    -- Test 1.3: Nil/empty result
    exec:reset()
    exec.intent = { TOOL = "shell", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    result = exec:feed_execution_result(nil)
    assert_truthy(exec.last_result:find("empty output"), "Handles nil output")
    -- Test 1.4: Empty string result
    exec:reset()
    exec.intent = { TOOL = "shell", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    result = exec:feed_execution_result("")
    assert_truthy(exec.last_result:find("empty output"), "Handles empty string output")
    -- Test 1.5: Table with only signal, no output
    exec:reset()
    exec.intent = { TOOL = "shell", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    result = exec:feed_execution_result({ signal = "PIPELINE_NEXT_STAGE" })
    assert_truthy(exec.last_result:find("PIPELINE_NEXT_STAGE"), "Contains signal when no output")
end
-- ============================================================================
-- TEST GROUP 2: Patch execution result includes file content for review
-- ============================================================================
print("\n[GROUP 2] Patch execution result enrichment")
do
    local ctx = mock_ctx()
    ctx.knowledge_base["src/test.lua"] = "local x = 1\nlocal y = 2\nlocal z = 3\n"
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 2.1: Patch tool includes file content after patching
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.payload = "src/test.lua\n<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 10\n>>>>>>> REPLACE"
    exec.state = multi_stage.STATES.COMMAND_READY
    local result = exec:feed_execution_result({ output = "[SUCCESS]: Applied 1 patch block(s) to src/test.lua.", signal = "MUTATION_SUCCESS" })
    assert_truthy(exec.last_result:find("<file_content_after_patch"), "Includes file_content_after_patch tag")
    assert_truthy(exec.last_result:find("local x = 1"), "Contains original file content (before patch would be applied)")
    -- Test 2.3: Non-patch tool does NOT include file content enrichment
    exec:reset()
    exec.intent = { TOOL = "shell", raw = "test" }
    exec.payload = "echo hello"
    exec.state = multi_stage.STATES.COMMAND_READY
    result = exec:feed_execution_result({ output = "hello" })
    assert_falsy(exec.last_result:find("<file_content_after_patch"), "Non-patch tools don't include file content enrichment")
end
-- ============================================================================
-- TEST GROUP 3: Intent parsing with various formats
-- ============================================================================
print("\n[GROUP 3] Intent parsing")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 3.1: Valid intent with all fields
    local intent, err = exec:parse_intent([[
<INTENT>
GOAL: Fix the bug in parser.c
TOOL: patch
PAYLOAD_HINT: Replace buffer overflow check with bounds validation
SUCCESS_CRITERIA: The patch applies cleanly and the test passes
</INTENT>
    ]])
    assert_truthy(intent, "Parses valid intent")
    assert_eq(intent.TOOL, "patch", "Extracts tool name")
    assert_truthy(intent.GOAL:find("bug"), "Extracts goal")
    assert_truthy(intent.PAYLOAD_HINT:find("buffer"), "Extracts payload hint")
    -- Test 3.2: Intent with extra whitespace
    intent, err = exec:parse_intent([[
<INTENT>
  GOAL:   Trim whitespace test  
  TOOL:   shell  
  PAYLOAD_HINT:   Echo test  
  SUCCESS_CRITERIA:   Output matches  
</INTENT>
    ]])
    assert_truthy(intent, "Parses intent with extra whitespace")
    assert_eq(intent.TOOL, "shell", "Trims tool name")
    -- Test 3.3: Missing GOAL field
    intent, err = exec:parse_intent([[
<INTENT>
TOOL: patch
PAYLOAD_HINT: Some hint
SUCCESS_CRITERIA: Works
</INTENT>
    ]])
    assert_falsy(intent, "Rejects intent missing GOAL")
    assert_truthy(err:find("GOAL"), "Error mentions GOAL")
    -- Test 3.4: Missing TOOL field
    intent, err = exec:parse_intent([[
<INTENT>
GOAL: Do something
PAYLOAD_HINT: Some hint
SUCCESS_CRITERIA: Works
</INTENT>
    ]])
    assert_falsy(intent, "Rejects intent missing TOOL")
    assert_truthy(err:find("TOOL"), "Error mentions TOOL")
    -- Test 3.5: Unknown tool
    intent, err = exec:parse_intent([[
<INTENT>
GOAL: Do something
TOOL: nonexistent_tool
PAYLOAD_HINT: Some hint
SUCCESS_CRITERIA: Works
</INTENT>
    ]])
    assert_falsy(intent, "Rejects intent with unknown tool")
    assert_truthy(err:find("nonexistent_tool"), "Error mentions unknown tool")
    -- Test 3.6: TOOL: NONE
    intent, err = exec:parse_intent([[
<INTENT>
GOAL: No tool needed
TOOL: NONE
PAYLOAD_HINT: N/A
SUCCESS_CRITERIA: N/A
</INTENT>
    ]])
    assert_falsy(intent, "Rejects TOOL: NONE")
    assert_truthy(err:find("no suitable tool"), "Error mentions no suitable tool")
    -- Test 3.7: No INTENT block at all
    intent, err = exec:parse_intent("Just some random text without intent block")
    assert_falsy(intent, "Rejects text without INTENT block")
    assert_truthy(err:find("INTENT"), "Error mentions INTENT block")
end
-- ============================================================================
-- TEST GROUP 4: Review parsing with APPROVE/REVISE verdicts
-- ============================================================================
print("\n[GROUP 4] Review parsing")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 4.1: Valid APPROVE review
    local review, err = exec:parse_review([[
<REVIEW>
VERDICT: APPROVE
CHECKLIST:
- [ ] Criteria 1: PASS — Looks good
- [ ] Criteria 2: PASS — Verified
CORRECTION:
None needed.
</REVIEW>
    ]])
    assert_truthy(review, "Parses valid APPROVE review")
    assert_eq(review.verdict, "APPROVE", "Verdict is APPROVE")
    assert_falsy(review.correction, "No correction for APPROVE")
    -- Test 4.2: Valid REVISE review
    review, err = exec:parse_review([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria 1: FAIL — Wrong indentation
- [ ] Criteria 2: PASS — OK
CORRECTION:
Fix the indentation in lines 5-10. Use 4 spaces instead of tabs.
</REVIEW>
    ]])
    assert_truthy(review, "Parses valid REVISE review")
    assert_eq(review.verdict, "REVISE", "Verdict is REVISE")
    assert_truthy(review.correction:find("indentation"), "Contains correction text")
    -- Test 4.3: Missing VERDICT
    review, err = exec:parse_review([[
<REVIEW>
CHECKLIST:
- [ ] Something: PASS
</REVIEW>
    ]])
    assert_falsy(review, "Rejects review missing VERDICT")
    assert_truthy(err:find("VERDICT"), "Error mentions VERDICT")
    -- Test 4.4: Invalid VERDICT value
    review, err = exec:parse_review([[
<REVIEW>
VERDICT: MAYBE
CHECKLIST:
- [ ] Something: PASS
</REVIEW>
    ]])
    assert_falsy(review, "Rejects invalid VERDICT value")
    assert_truthy(err:find("Invalid VERDICT"), "Error mentions invalid VERDICT")
    -- Test 4.5: REVISE without CORRECTION
    review, err = exec:parse_review([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Something: FAIL
</REVIEW>
    ]])
    assert_falsy(review, "Rejects REVISE without CORRECTION")
    assert_truthy(err:find("CORRECTION"), "Error mentions CORRECTION")
    -- Test 4.6: Case-insensitive VERDICT
    review, err = exec:parse_review([[
<REVIEW>
VERDICT: approve
CHECKLIST:
- [ ] Something: PASS
</REVIEW>
    ]])
    assert_truthy(review, "Parses lowercase verdict")
    assert_eq(review.verdict, "APPROVE", "Normalizes verdict to uppercase")
end
-- ============================================================================
-- TEST GROUP 5: Payload sanitization edge cases
-- ============================================================================
print("\n[GROUP 5] Payload sanitization")
do
    -- Access the internal sanitize_payload function via feed_response flow
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 5.1: Markdown fences are stripped
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    local result = exec:feed_response("```lua\nlocal x = 1\n```")
    -- After sanitization, the payload should not have markdown fences
    assert_falsy(exec.payload:find("```"), "Strips markdown fences")
    assert_truthy(exec.payload:find("local x = 1"), "Preserves content")
    -- Test 5.2: Thinking tags are stripped
    exec:reset()
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    result = exec:feed_response("<thinking>Let me think...</thinking>\nlocal x = 1")
    assert_falsy(exec.payload:find("<thinking>"), "Strips thinking tags")
    assert_truthy(exec.payload:find("local x = 1"), "Preserves content after tags")
    -- Test 5.3: Preamble phrases are stripped (lowercase only)
    exec:reset()
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    -- The sanitize_payload function uses lowercase regex patterns
    result = exec:feed_response("here is the payload:\nlocal x = 1")
    -- Check that the content is preserved (preamble may or may not be stripped depending on case)
    assert_truthy(exec.payload:find("local x = 1"), "Preserves content after preamble")
    -- Test 5.4: ||| COMMAND ||| wrappers are stripped
    exec:reset()
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    result = exec:feed_response("||| COMMAND |||\npatch:test.lua\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE\n||| END_COMMAND |||")
    assert_falsy(exec.payload:find("||| COMMAND |||"), "Strips command wrappers")
    assert_truthy(exec.payload:find("patch:test.lua"), "Preserves payload content")
    -- Test 5.5: Empty payload handling
    exec:reset()
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    result = exec:feed_response("")
    -- Empty payload triggers validation retry (generate stage), not immediate error
    -- After max_validation_retries, it becomes an error
    assert_truthy(result.stage == "generate" or result.stage == "error", "Empty payload triggers validation retry or error")
end
-- ============================================================================
-- TEST GROUP 6: max_iterations enforcement
-- ============================================================================
print("\n[GROUP 6] max_iterations enforcement")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 2 })
    -- Simulate a task that keeps getting REVISE verdicts
    exec:start_task("Test task", "")
    -- Feed intent response
    local step = exec:feed_response([[
<INTENT>
GOAL: Test goal
TOOL: shell
PAYLOAD_HINT: Echo test
SUCCESS_CRITERIA: Output matches
</INTENT>
    ]])
    assert_eq(step.stage, "generate", "Moves to generate after intent")
    -- Feed payload (iteration 1)
    step = exec:feed_response("echo hello")
    assert_eq(step.stage, "execute", "Moves to execute after payload")
    -- Execute and feed result
    step = exec:feed_execution_result({ output = "hello" })
    assert_eq(step.stage, "review", "Moves to review after execution")
    -- Feed REVISE (iteration 1 -> 2)
    step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria: FAIL — Wrong output
CORRECTION:
Use echo world instead.
</REVIEW>
    ]])
    assert_eq(step.stage, "generate", "Revise triggers regenerate")
    -- Feed new payload (iteration 2)
    step = exec:feed_response("echo world")
    assert_eq(step.stage, "execute", "Moves to execute after revised payload")
    -- Execute and feed result
    step = exec:feed_execution_result({ output = "world" })
    assert_eq(step.stage, "review", "Moves to review after execution")
    -- Feed REVISE again (iteration 2 -> would be 3, but max is 2)
    step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria: FAIL — Still wrong
CORRECTION:
Try something else.
</REVIEW>
    ]])
    assert_eq(step.stage, "error", "Exceeds max_iterations causes error")
    assert_truthy(step.message:find("Failed to satisfy intent"), "Error mentions iteration failure")
end
-- ============================================================================
-- TEST GROUP 7: Correction merging across iterations
-- ============================================================================
print("\n[GROUP 7] Correction merging")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 5 })
    exec:start_task("Test task", "")
    -- Feed intent
    local step = exec:feed_response([[
<INTENT>
GOAL: Test goal
TOOL: shell
PAYLOAD_HINT: Echo test
SUCCESS_CRITERIA: Output matches
</INTENT>
    ]])
    -- Feed payload
    step = exec:feed_response("echo hello")
    step = exec:feed_execution_result({ output = "hello" })
    -- First REVISE
    step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION:
Correction 1: Use double quotes.
</REVIEW>
    ]])
    assert_truthy(exec.intent_raw:find("Correction 1"), "First correction merged")
    -- Second REVISE
    step = exec:feed_response("echo \"hello\"")
    step = exec:feed_execution_result({ output = "hello" })
    step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION:
Correction 2: Add -n flag.
</REVIEW>
    ]])
    assert_truthy(exec.intent_raw:find("Correction 2"), "Second correction merged")
    assert_truthy(exec.intent_raw:find("Correction 1"), "First correction still present")
    -- Third REVISE (should trigger summarization of older corrections)
    step = exec:feed_response("echo -n \"hello\"")
    step = exec:feed_execution_result({ output = "hello" })
    step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION:
Correction 3: Use printf instead.
</REVIEW>
    ]])
    assert_truthy(exec.intent_raw:find("Correction 3"), "Third correction merged")
    -- With 3 corrections, older ones should be summarized
    assert_truthy(exec.intent_raw:find("Accumulated reviewer notes"), "Older corrections summarized")
end
-- ============================================================================
-- TEST GROUP 8: start_task_with_intent flow
-- ============================================================================
print("\n[GROUP 8] start_task_with_intent flow")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 8.1: Valid start_task_with_intent
    local step = exec:start_task_with_intent(
        "Fix the bug",
        "Project context",
        "patch",
        "Replace buffer check",
        "Patch applies cleanly"
    )
    assert_eq(step.stage, "generate", "Skips intent, goes to generate")
    assert_eq(exec.intent.TOOL, "patch", "Tool is set correctly")
    assert_truthy(exec.intent.GOAL:find("Fix the bug"), "Goal is set correctly")
    -- Test 8.2: Empty tool_name
    step = exec:start_task_with_intent("Task", "Ctx", "", "Hint", "Criteria")
    assert_eq(step.stage, "error", "Empty tool_name causes error")
    -- Test 8.3: Unknown tool_name
    step = exec:start_task_with_intent("Task", "Ctx", "nonexistent", "Hint", "Criteria")
    assert_eq(step.stage, "error", "Unknown tool_name causes error")
    -- Test 8.4: Full flow with start_task_with_intent
    exec:reset()
    step = exec:start_task_with_intent("Task", "Ctx", "shell", "Echo test", "Output matches")
    assert_eq(step.stage, "generate", "Valid start_task_with_intent goes to generate")
    -- Feed payload
    step = exec:feed_response("echo test")
    assert_eq(step.stage, "execute", "Goes to execute after payload")
    -- Execute
    step = exec:feed_execution_result({ output = "test" })
    assert_eq(step.stage, "review", "Goes to review after execution")
    -- Approve
    step = exec:feed_response([[
<REVIEW>
VERDICT: APPROVE
CHECKLIST:
- [ ] Output matches: PASS
CORRECTION:
None.
</REVIEW>
    ]])
    assert_eq(step.stage, "done", "Approve completes the task")
    assert_eq(step.iterations, 1, "Completed in 1 iteration")
end
-- ============================================================================
-- TEST GROUP 9: Token budget force-approval
-- ============================================================================
print("\n[GROUP 9] Token budget force-approval")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", {
        max_iterations = 10,
        max_tokens_per_task = 100  -- Very low budget for testing
    })
    exec:start_task("Test task", "")
    -- Feed intent
    local step = exec:feed_response([[
<INTENT>
GOAL: Test goal
TOOL: shell
PAYLOAD_HINT: Echo test
SUCCESS_CRITERIA: Output matches
</INTENT>
    ]])
    -- Feed payload
    step = exec:feed_response("echo hello")
    step = exec:feed_execution_result({ output = "hello" })
    -- Simulate exceeding token budget
    exec.total_tokens_used = 200  -- Exceeds max_tokens_per_task of 100
    -- Feed review (should force-approve regardless of verdict)
    step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria: FAIL
CORRECTION:
Something wrong.
</REVIEW>
    ]])
    assert_eq(step.stage, "done", "Token budget exceeded forces approval")
    assert_truthy(step.forced_approval, "Flagged as forced approval")
end
-- ============================================================================
-- TEST GROUP 10: Payload validation
-- ============================================================================
print("\n[GROUP 10] Payload validation")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 10.1: delegate_plan requires valid JSON
    exec.intent = { TOOL = "delegate_plan", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    local step = exec:feed_response("not valid json")
    -- Invalid JSON triggers validation retry (generate), not immediate error
    assert_truthy(step.stage == "generate" or step.stage == "error", "Invalid JSON for delegate_plan triggers retry or error")
    -- Test 10.2: delegate_plan requires plan and memo
    exec:reset()
    exec.intent = { TOOL = "delegate_plan", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    step = exec:feed_response('{ "plan": [] }')
    -- Missing memo triggers validation retry (generate), not immediate error
    assert_truthy(step.stage == "generate" or step.stage == "error", "Missing memo for delegate_plan triggers retry or error")
    -- Test 10.3: patch requires SEARCH/REPLACE blocks
    exec:reset()
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    step = exec:feed_response("just some text without search/replace")
    -- Missing SEARCH/REPLACE triggers validation retry (generate), not immediate error
    assert_truthy(step.stage == "generate" or step.stage == "error", "Missing SEARCH/REPLACE for patch triggers retry or error")
    -- Test 10.4: create_file requires file path
    exec:reset()
    exec.intent = { TOOL = "create_file", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    step = exec:feed_response("")
    -- Empty payload triggers validation retry (generate), not immediate error
    assert_truthy(step.stage == "generate" or step.stage == "error", "Empty payload for create_file triggers retry or error")
end
-- ============================================================================
-- TEST GROUP 11: generate_unified_diff produces correct diff output
-- ============================================================================
print("\n[GROUP 11] generate_unified_diff")
do
    local patcher = require("patcher")
    -- Test 11.1: Identical files produce empty diff
    local old_lines = {"line 1", "line 2", "line 3"}
    local new_lines = {"line 1", "line 2", "line 3"}
    local diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
    assert_eq(diff, "", "Identical files produce empty diff")
    -- Test 11.2: Single line change produces diff with context
    old_lines = {"line 1", "line 2", "line 3", "line 4", "line 5"}
    new_lines = {"line 1", "line 2", "CHANGED", "line 4", "line 5"}
    diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
    assert_truthy(diff:find("--- test.txt"), "Diff contains old filename")
    assert_truthy(diff:find("+++ test.txt"), "Diff contains new filename")
    assert_truthy(diff:find("@@"), "Diff contains hunk header")
    assert_truthy(diff:find("-line 3"), "Diff contains removed line")
    assert_truthy(diff:find("+CHANGED"), "Diff contains added line")
    -- Test 11.3: Added lines at end
    old_lines = {"line 1", "line 2"}
    new_lines = {"line 1", "line 2", "line 3", "line 4"}
    diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
    assert_truthy(diff:find("+line 3"), "Diff contains added line 3")
    assert_truthy(diff:find("+line 4"), "Diff contains added line 4")
    -- Test 11.4: Removed lines
    old_lines = {"line 1", "line 2", "line 3", "line 4"}
    new_lines = {"line 1", "line 2"}
    diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
    assert_truthy(diff:find("-line 3"), "Diff contains removed line 3")
    assert_truthy(diff:find("-line 4"), "Diff contains removed line 4")
    -- Test 11.5: Empty old file
    old_lines = {}
    new_lines = {"line 1", "line 2"}
    diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
    assert_truthy(diff:find("+line 1"), "Diff contains added line from empty file")
    -- Test 11.6: Empty new file
    old_lines = {"line 1", "line 2"}
    new_lines = {}
    diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
    assert_truthy(diff:find("-line 1"), "Diff contains removed line to empty file")
end
-- ============================================================================
-- TEST GROUP 12: Patch success output contains diff block
-- ============================================================================
print("\n[GROUP 12] Patch success output with diff")
do
    -- We need to test that patcher.apply_patch returns diff as 4th value
    local patcher = require("patcher")
    -- Test 12.1: Successful patch returns diff string
    local original = "line 1\nline 2\nline 3\n"
    local patch_body = "<<<<<<< SEARCH\nline 2\n=======\nCHANGED\n>>>>>>> REPLACE"
    local ok, new_content, changes, diff_str = patcher.apply_patch(original, patch_body)
    assert_truthy(ok, "Patch applies successfully")
    assert_eq(changes, 1, "One change applied")
    assert_truthy(diff_str, "Diff string is returned")
    assert_truthy(diff_str:find("-line 2"), "Diff contains removed line")
    assert_truthy(diff_str:find("+CHANGED"), "Diff contains added line")
    -- Test 12.2: Failed patch returns error message as 3rd value
    local original = "line 1\nline 2\nline 3\n"
    local patch_body = "<<<<<<< SEARCH\nNONEXISTENT\n=======\nCHANGED\n>>>>>>> REPLACE"
    ok, new_content, changes, diff_str = patcher.apply_patch(original, patch_body)
    assert_falsy(ok, "Patch fails for nonexistent search")
    assert_truthy(changes, "Error message is returned as 3rd value")
    assert_truthy(tostring(changes):find("FAILED"), "Error message contains FAILED")
    -- Test 12.3: Zero-op patch (SEARCH == REPLACE) fails
    local original = "line 1\nline 2\nline 3\n"
    local patch_body = "<<<<<<< SEARCH\nline 2\n=======\nline 2\n>>>>>>> REPLACE"
    ok, new_content, changes, diff_str = patcher.apply_patch(original, patch_body)
    assert_falsy(ok, "Zero-op patch fails")
end
-- ============================================================================
-- TEST GROUP 13: feed_execution_result handles table with output field
-- ============================================================================
print("\n[GROUP 13] feed_execution_result table handling")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 13.1: Table with output and signal fields
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    local result = exec:feed_execution_result({
        output = "Patch applied successfully",
        signal = "MUTATION_SUCCESS"
    })
    assert_eq(result.stage, "review", "Returns review stage")
    assert_truthy(exec.last_result:find("Patch applied successfully"), "Contains output string")
    assert_truthy(exec.last_result:find("MUTATION_SUCCESS"), "Contains signal")
    -- Test 13.2: Table with only output field
    exec:reset()
    exec.intent = { TOOL = "shell", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    result = exec:feed_execution_result({ output = "Just output" })
    assert_truthy(exec.last_result:find("Just output"), "Contains output without signal")
    assert_falsy(exec.last_result:find("SIGNAL"), "No signal when not provided")
    -- Test 13.3: Table with nil output
    exec:reset()
    exec.intent = { TOOL = "shell", raw = "test" }
    exec.state = multi_stage.STATES.COMMAND_READY
    result = exec:feed_execution_result({ signal = "SOME_SIGNAL" })
    assert_truthy(exec.last_result:find("SOME_SIGNAL"), "Contains signal when output is nil")
end
-- ============================================================================
-- TEST GROUP 14: Review prompt includes tool-specific checks
-- ============================================================================
print("\n[GROUP 14] Review prompt tool-specific checks")
do
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    -- Test 14.1: Patch review prompt includes file_content_after_patch check
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.payload = "some payload"
    exec.last_result = "some result"
    local prompt = exec:build_review_prompt()
    assert_truthy(prompt:find("file_content_after_patch"), "Patch review prompt mentions file_content_after_patch")
    assert_truthy(prompt:find("SEARCH block"), "Patch review prompt mentions SEARCH blocks")
    -- Test 14.2: create_file review prompt includes file creation checks
    exec.intent = { TOOL = "create_file", raw = "test" }
    prompt = exec:build_review_prompt()
    assert_truthy(prompt:find("file created"), "create_file review prompt mentions file creation")
    -- Test 14.3: delegate_plan review prompt includes JSON checks
    exec.intent = { TOOL = "delegate_plan", raw = "test" }
    prompt = exec:build_review_prompt()
    assert_truthy(prompt:find("JSON"), "delegate_plan review prompt mentions JSON")
    assert_truthy(prompt:find("memo"), "delegate_plan review prompt mentions memo")
end
-- ============================================================================
-- TEST GROUP 15: TOOL_MULTI_STAGE_DOCS centralization & empty-command detection
-- ============================================================================
print("\n[GROUP 15] TOOL_MULTI_STAGE_DOCS centralization & empty-command detection")
do
    local states = require("multi_stage_executor.states")
    -- Test 15.1: TOOL_MULTI_STAGE_DOCS exists and has entries for patch
    assert_truthy(states.TOOL_MULTI_STAGE_DOCS, "TOOL_MULTI_STAGE_DOCS table exists")
    assert_truthy(states.TOOL_MULTI_STAGE_DOCS.patch, "TOOL_MULTI_STAGE_DOCS has 'patch' entry")
    assert_truthy(states.TOOL_MULTI_STAGE_DOCS.patch:find("SEARCH/REPLACE"), "patch doc mentions SEARCH/REPLACE")
    -- Test 15.2: TOOL_MULTI_STAGE_DOCS has entry for create_file
    assert_truthy(states.TOOL_MULTI_STAGE_DOCS.create_file, "TOOL_MULTI_STAGE_DOCS has 'create_file' entry")
    assert_truthy(states.TOOL_MULTI_STAGE_DOCS.create_file:find("file content"), "create_file doc mentions file content")
    -- Test 15.3: TOOL_MULTI_STAGE_DOCS has entry for delegate_plan
    assert_truthy(states.TOOL_MULTI_STAGE_DOCS.delegate_plan, "TOOL_MULTI_STAGE_DOCS has 'delegate_plan' entry")
    assert_truthy(states.TOOL_MULTI_STAGE_DOCS.delegate_plan:find("JSON"), "delegate_plan doc mentions JSON")
    -- Test 15.4: Empty-command detection for patch: 'patch:path' with no SEARCH block => has_payload=false
    -- Simulate the logic from agent/turn.lua
    local function detect_patch_payload(cmd)
        local args_part = cmd:match("^patch:%s*(.*)")
        if not args_part then return nil, nil end
        local first_line = args_part:match("^[^\r\n]+")
        local file_path = first_line and first_line:gsub("^%s*(.-)%s*$", "%1") or nil
        local has_payload = args_part:find("<<<<<<< SEARCH") and true or false
        return file_path, has_payload
    end
    local fp, hp = detect_patch_payload("patch:src/main.c")
    assert_eq(fp, "src/main.c", "Extracts file path from patch command")
    assert_eq(hp, false, "patch:path with no SEARCH block => has_payload=false (Phase 1)")
    fp, hp = detect_patch_payload("patch:src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
    assert_eq(fp, "src/main.c", "Extracts file path from patch with payload")
    assert_eq(hp, true, "patch:path with SEARCH block => has_payload=true (Phase 2)")
    -- Test 15.5: Empty-command detection for create_file: 'create_file:path' with no content => has_payload=false
    local function detect_create_file_payload(cmd)
        local args_part = cmd:match("^create_file:%s*(.*)")
        if not args_part or args_part:gsub("^%s*(.-)%s*$", "%1") == "" then return nil, false end
        local first_line = args_part:match("^[^\r\n]+")
        local file_path = first_line and first_line:gsub("^%s*(.-)%s*$", "%1") or nil
        local rest = args_part:match("^[^\r\n]+\r?\n(.*)")
        local has_payload = (rest and rest:gsub("^%s*(.-)%s*$", "%1") ~= "") and true or false
        return file_path, has_payload
    end
    local fp2, hp2 = detect_create_file_payload("create_file:src/new.lua")
    assert_eq(fp2, "src/new.lua", "Extracts file path from create_file command")
    assert_eq(hp2, false, "create_file:path with no content => has_payload=false (Phase 1)")
    fp2, hp2 = detect_create_file_payload("create_file:src/new.lua\nlocal x = 1")
    assert_eq(fp2, "src/new.lua", "Extracts file path from create_file with content")
    assert_eq(hp2, true, "create_file:path with content => has_payload=true (Phase 2)")
    -- Test 15.6: multi_stage_executor prepends file_path to payload during execution
    local ctx = mock_ctx()
    local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
    exec.intent = { TOOL = "patch", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    exec.file_path = "src/test.lua"
    local step = exec:feed_response("<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
    assert_eq(step.stage, "execute", "Moves to execute after valid payload")
    assert_truthy(step.payload:find("^src/test.lua"), "file_path is prepended to effective_payload")
    assert_truthy(step.payload:find("<<<<<<< SEARCH"), "SEARCH block is preserved in effective_payload")
    -- Test 15.7: create_file with file_path prepending
    exec:reset()
    exec.intent = { TOOL = "create_file", raw = "test" }
    exec.state = multi_stage.STATES.INTENT_READY
    exec.file_path = "src/new.lua"
    step = exec:feed_response("local x = 1")
    assert_eq(step.stage, "execute", "Moves to execute after valid create_file payload")
    assert_truthy(step.payload:find("^src/new.lua"), "file_path is prepended to create_file effective_payload")
    assert_truthy(step.payload:find("local x = 1"), "Content is preserved in effective_payload")
end
-- ============================================================================
-- SUMMARY
-- ============================================================================
print(string.format("\n=== RESULTS: %d/%d passed, %d failed ===", passed, total, failed))
if failed > 0 then
    os.exit(1)
end
return M