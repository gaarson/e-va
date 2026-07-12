#!/usr/bin/env lua
-- Comprehensive test suite for multi_stage_executor and related modules
-- Standalone: no external test framework, plain Lua with assert() and print()
package.path = package.path .. ";../?.lua;../../?.lua;../../tools/?.lua"
-- Mock tool_registry BEFORE requiring multi_stage_executor
-- This ensures the registry is available when multi_stage_executor loads
package.preload["tool_registry"] = function()
    local M = {}
    M.tools = {
        patch = { name = "patch", desc = "Apply patches" },
        create_file = { name = "create_file", desc = "Create files" },
        shell = { name = "shell", desc = "Run shell commands" },
        read_file = { name = "read_file", desc = "Read files" },
        delegate_plan = { name = "delegate_plan", desc = "Delegate plans" },
        batch_patch = { name = "batch_patch", desc = "Batch patches" },
    }
    function M.is_tool_allowed(agent_cfg, tool_name)
        if not agent_cfg or not agent_cfg.allowed_tools then return true end
        for _, t in ipairs(agent_cfg.allowed_tools) do
            if t == tool_name then return true end
        end
        return false
    end
    return M
end
local patcher = require("patcher")
local multi_stage = require("multi_stage_executor")
local utils = require("utils")
-- ============================================================
-- Test Harness
-- ============================================================
local pass_count = 0
local fail_count = 0
local failures = {}
local function run_test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        print(string.format("  PASS: %s", name))
    else
        fail_count = fail_count + 1
        table.insert(failures, { name = name, error = tostring(err) })
        print(string.format("  FAIL: %s — %s", name, tostring(err)))
    end
end
local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %q, got %q", msg or "assertion failed", b, a))
    end
end
local function assert_truthy(v, msg)
    if not v then
        error(msg or "expected truthy value")
    end
end
local function assert_falsy(v, msg)
    if v then
        error(msg or "expected falsy value")
    end
end
local function assert_contains(haystack, needle, msg)
    if not haystack:find(needle, 1, true) then
        error(string.format("%s: expected %q to contain %q", msg or "assertion failed", haystack, needle))
    end
end
-- ============================================================
-- Tests for patcher.lua
-- ============================================================
print("\n=== patcher.lua ===")
-- NOTE: generate_unified_diff has a known bug where fuzzy_line_eq is called
-- before it's defined (forward reference issue at line 37). The function is
-- defined as local at line 122. These tests document expected behavior once fixed.
run_test("apply_patch returns 4 values on success (KNOWN BUG: fuzzy_line_eq forward ref)", function()
    local content = "line1\nline2\nline3"
    local patch = [[<<<<<<< SEARCH
line2
=======
line2_modified
>>>>>>> REPLACE]]
    local ok, new_content, count, diff_str = patcher.apply_patch(content, patch)
    assert_truthy(ok, "apply_patch should return true on success")
    assert_truthy(new_content, "should return new content")
    assert_truthy(count, "should return change count")
    assert_truthy(type(diff_str) == "string", "should return diff string (4th value)")
end)
run_test("apply_patch correctly modifies content (KNOWN BUG: fuzzy_line_eq forward ref)", function()
    local content = "line1\nline2\nline3"
    local patch = [[<<<<<<< SEARCH
line2
=======
line2_modified
>>>>>>> REPLACE]]
    local ok, new_content = patcher.apply_patch(content, patch)
    assert_truthy(ok, "patch should succeed")
    assert_contains(new_content, "line2_modified", "content should contain modified line")
end)
run_test("apply_patch returns false for invalid blocks (no SEARCH)", function()
    local content = "some content"
    local patch = "just some random text"
    local ok, err = patcher.apply_patch(content, patch)
    assert_falsy(ok, "should return false for invalid patch")
    assert_truthy(err, "should return error message")
end)
run_test("apply_patch returns false for empty SEARCH block", function()
    local content = "some content"
    local patch = [[<<<<<<< SEARCH
=======
replacement
>>>>>>> REPLACE]]
    local ok, err = patcher.apply_patch(content, patch)
    assert_falsy(ok, "should return false for empty SEARCH block")
    assert_truthy(err, "should return error message")
end)
run_test("apply_patch returns false for identical SEARCH and REPLACE", function()
    local content = "line1\nline2\nline3"
    local patch = [[<<<<<<< SEARCH
line2
=======
line2
>>>>>>> REPLACE]]
    local ok, err = patcher.apply_patch(content, patch)
    assert_falsy(ok, "should return false for identical SEARCH/REPLACE")
    assert_truthy(err, "should return error message")
end)
run_test("apply_patch handles multiple SEARCH/REPLACE blocks (KNOWN BUG: fuzzy_line_eq forward ref)", function()
    local content = "aaa\nbbb\nccc\nddd"
    local patch = [[<<<<<<< SEARCH
aaa
=======
AAA
>>>>>>> REPLACE
<<<<<<< SEARCH
ccc
=======
CCC
>>>>>>> REPLACE]]
    local ok, new_content, count = patcher.apply_patch(content, patch)
    assert_truthy(ok, "multiple patches should succeed")
    assert_contains(new_content, "AAA", "should replace aaa")
    assert_contains(new_content, "CCC", "should replace ccc")
    assert_eq(count, 2, "should report 2 changes")
end)
run_test("apply_patch generates unified diff as 4th return value (KNOWN BUG: fuzzy_line_eq forward ref)", function()
    local content = "line1\nline2\nline3"
    local patch = [[<<<<<<< SEARCH
line2
=======
line2_modified
>>>>>>> REPLACE]]
    local ok, new_content, count, diff_str = patcher.apply_patch(content, patch)
    assert_truthy(ok, "patch should succeed")
    assert_truthy(type(diff_str) == "string", "diff_str should be a string")
    assert_truthy(#diff_str > 0, "diff_str should not be empty")
    assert_contains(diff_str, "---", "diff should contain --- header")
    assert_contains(diff_str, "+++", "diff should contain +++ header")
end)
-- ============================================================
-- Tests for multi_stage_executor.lua
-- ============================================================
print("\n=== multi_stage_executor.lua ===")
-- Helper: create a mock context
local function make_mock_ctx()
    local ctx = {
        config = {
            PROJECT_ROOT = "/tmp/test_project",
            AGENTS = {
                test_agent = {
                    allowed_tools = {"patch", "create_file", "shell", "read_file", "delegate_plan", "batch_patch"}
                }
            },
            CREATE_BACKUPS = false
        },
        knowledge_base = {},
        file_states = {},
        squash_last_mutation = function(self, name) end,
        add_file = function(self, path, content)
            self.knowledge_base[path] = content
        end
    }
    return ctx
end
run_test("parse_intent extracts fields from valid INTENT block", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local intent, err = executor:parse_intent([[
<INTENT>
GOAL: Fix the bug in main.c
TOOL: patch
PAYLOAD_HINT: Replace buffer size check
SUCCESS_CRITERIA: Buffer overflow is eliminated
</INTENT>
]])
    assert_truthy(intent, "should parse intent")
    assert_falsy(err, "should have no error")
    assert_contains(intent.GOAL, "bug", "GOAL should contain 'bug'")
    assert_eq(intent.TOOL, "patch", "TOOL should be 'patch'")
end)
run_test("parse_intent rejects missing INTENT block", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local intent, err = executor:parse_intent("Just some text without tags")
    assert_falsy(intent, "should return nil intent")
    assert_truthy(err, "should return error")
end)
run_test("parse_intent rejects missing GOAL field", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local intent, err = executor:parse_intent([[
<INTENT>
TOOL: patch
</INTENT>
]])
    assert_falsy(intent, "should return nil intent")
    assert_truthy(err, "should return error about missing GOAL")
end)
run_test("parse_intent rejects missing TOOL field", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local intent, err = executor:parse_intent([[
<INTENT>
GOAL: Do something
</INTENT>
]])
    assert_falsy(intent, "should return nil intent")
    assert_truthy(err, "should return error about missing TOOL")
end)
run_test("parse_intent rejects TOOL: NONE", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local intent, err = executor:parse_intent([[
<INTENT>
GOAL: Do something
TOOL: NONE
</INTENT>
]])
    assert_falsy(intent, "should return nil intent")
    assert_truthy(err, "should return error about NONE tool")
end)
run_test("parse_review extracts APPROVE verdict", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local review, err = executor:parse_review([[
<REVIEW>
VERDICT: APPROVE
CHECKLIST:
- [ ] Criteria 1: PASS
</REVIEW>
]])
    assert_truthy(review, "should parse review")
    assert_falsy(err, "should have no error")
    assert_eq(review.verdict, "APPROVE", "verdict should be APPROVE")
    assert_falsy(review.correction, "APPROVE should have no correction")
end)
run_test("parse_review extracts REVISE verdict with correction", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local review, err = executor:parse_review([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria 1: FAIL
CORRECTION:
Fix the indentation on line 5.
</REVIEW>
]])
    assert_truthy(review, "should parse review")
    assert_falsy(err, "should have no error")
    assert_eq(review.verdict, "REVISE", "verdict should be REVISE")
    assert_truthy(review.correction, "REVISE should have correction")
    assert_contains(review.correction, "indentation", "correction should mention indentation")
end)
run_test("parse_review rejects missing VERDICT", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local review, err = executor:parse_review([[
<REVIEW>
CHECKLIST:
- [ ] Something
</REVIEW>
]])
    assert_falsy(review, "should return nil review")
    assert_truthy(err, "should return error about missing VERDICT")
end)
run_test("parse_review rejects invalid VERDICT", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local review, err = executor:parse_review([[
<REVIEW>
VERDICT: MAYBE
</REVIEW>
]])
    assert_falsy(review, "should return nil review")
    assert_truthy(err, "should return error about invalid VERDICT")
end)
run_test("parse_review rejects REVISE without CORRECTION", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    local review, err = executor:parse_review([[
<REVIEW>
VERDICT: REVISE
</REVIEW>
]])
    assert_falsy(review, "should return nil review")
    assert_truthy(err, "should return error about missing CORRECTION")
end)
run_test("feed_execution_result extracts output.output from table result", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "test_payload"
    executor.state = multi_stage.STATES.COMMAND_READY
    
    local result = executor:feed_execution_result({ output = "Patch applied successfully", signal = "MUTATION_SUCCESS" })
    
    assert_eq(result.stage, "review", "should transition to review stage")
    assert_truthy(executor.last_result, "should store last_result")
    assert_contains(executor.last_result, "Patch applied successfully", "last_result should contain output string")
    assert_contains(executor.last_result, "MUTATION_SUCCESS", "last_result should contain signal")
end)
run_test("feed_execution_result handles string result", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor.intent = { TOOL = "shell", raw = "GOAL: test\nTOOL: shell" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "echo hello"
    executor.state = multi_stage.STATES.COMMAND_READY
    
    local result = executor:feed_execution_result("Command output here")
    
    assert_eq(result.stage, "review", "should transition to review stage")
    assert_contains(executor.last_result, "Command output here", "last_result should contain string output")
end)
run_test("feed_execution_result enriches patch result with file content from knowledge_base", function()
    local ctx = make_mock_ctx()
    ctx.knowledge_base["src/main.c"] = "int main() { return 0; }\n"
    
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"
    executor.state = multi_stage.STATES.COMMAND_READY
    
    local result = executor:feed_execution_result({ output = "Applied 1 patch block(s) to src/main.c" })
    
    assert_eq(result.stage, "review", "should transition to review stage")
    assert_contains(executor.last_result, "<file_content_after_patch", "should inject file content after patch")
    assert_contains(executor.last_result, "int main()", "file content should be included")
end)
run_test("start_task_with_intent skips intent phase", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    local result = executor:start_task_with_intent(
        "Fix the bug",
        "Project context",
        "patch",
        "Replace buffer check",
        "Buffer overflow eliminated"
    )
    
    assert_eq(result.stage, "generate", "should skip to generate stage")
    assert_eq(executor.state, multi_stage.STATES.INTENT_READY, "state should be INTENT_READY")
    assert_eq(executor.intent.TOOL, "patch", "intent tool should be patch")
end)
run_test("start_task_with_intent rejects unknown tool", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    local result = executor:start_task_with_intent(
        "Task",
        "Context",
        "nonexistent_tool",
        "Hint",
        "Criteria"
    )
    
    assert_eq(result.stage, "error", "should return error stage")
    assert_contains(result.message, "unknown tool", "error should mention unknown tool")
end)
run_test("start_task_with_intent rejects empty tool name", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    local result = executor:start_task_with_intent(
        "Task",
        "Context",
        "",
        "Hint",
        "Criteria"
    )
    
    assert_eq(result.stage, "error", "should return error stage")
    assert_contains(result.message, "empty", "error should mention empty tool")
end)
run_test("start_task begins with intent draft stage", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    local result = executor:start_task("Fix the bug", "Project context")
    
    assert_eq(result.stage, "intent", "should start with intent stage")
    assert_eq(executor.state, multi_stage.STATES.INTENT_DRAFT, "state should be INTENT_DRAFT")
end)
run_test("feed_response transitions from INTENT_DRAFT to INTENT_READY", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    executor:start_task("Fix bug", "Context")
    
    local result = executor:feed_response([[
<INTENT>
GOAL: Fix the bug in main.c
TOOL: patch
PAYLOAD_HINT: Replace buffer check
SUCCESS_CRITERIA: No buffer overflow
</INTENT>
]])
    
    assert_eq(result.stage, "generate", "should transition to generate stage")
    assert_eq(executor.state, multi_stage.STATES.INTENT_READY, "state should be INTENT_READY")
end)
run_test("feed_response transitions from INTENT_READY to COMMAND_READY", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor:start_task_with_intent(
        "Fix bug", "Context", "patch", "Replace check", "No overflow"
    )
    
    local result = executor:feed_response([[src/main.c
<<<<<<< SEARCH
old_code
=======
new_code
>>>>>>> REPLACE]])
    
    assert_eq(result.stage, "execute", "should transition to execute stage")
    assert_eq(executor.state, multi_stage.STATES.COMMAND_READY, "state should be COMMAND_READY")
    assert_contains(result.payload, "SEARCH", "payload should contain SEARCH block")
end)
run_test("max_iterations enforcement causes error", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent", { max_iterations = 2 })
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "payload"
    executor.last_result = "result"
    executor.state = multi_stage.STATES.REVIEWING
    executor.iteration = 2
    
    local result = executor:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION: Fix this
</REVIEW>
]])
    
    assert_eq(result.stage, "error", "should return error at max iterations")
    assert_contains(result.message, tostring(executor.max_iterations), "error should mention iteration count")
end)
run_test("token budget force-approval prevents runaway consumption", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent", { max_tokens_per_task = 100 })
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "payload"
    executor.last_result = "result"
    executor.state = multi_stage.STATES.REVIEWING
    executor.iteration = 1
    executor.total_tokens_used = 200
    
    local result = executor:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION: Fix this
</REVIEW>
]])
    
    assert_eq(result.stage, "done", "should force-approve due to token budget")
    assert_truthy(result.forced_approval, "should indicate forced approval")
end)
run_test("review parse failure with APPROVE inferred auto-approves", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "payload"
    executor.last_result = "result"
    executor.state = multi_stage.STATES.REVIEWING
    executor.iteration = 1
    
    local result = executor:feed_response("I APPROVE this change, looks good!")
    
    assert_eq(result.stage, "done", "should auto-approve when APPROVE is inferred")
end)
run_test("review parse failure with REVISE inferred enters revision", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "payload"
    executor.last_result = "result"
    executor.state = multi_stage.STATES.REVIEWING
    executor.iteration = 1
    
    local result = executor:feed_response("This needs REVISE, there's an ERROR")
    
    assert_eq(result.stage, "generate", "should enter revision when REVISE is inferred")
end)
run_test("reset clears all state", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor:start_task("Task", "Context")
    assert_eq(executor.state, multi_stage.STATES.INTENT_DRAFT, "should be in INTENT_DRAFT")
    
    executor:reset()
    
    assert_eq(executor.state, multi_stage.STATES.IDLE, "should be IDLE after reset")
    assert_falsy(executor.task, "task should be nil")
    assert_falsy(executor.intent, "intent should be nil")
    assert_falsy(executor.payload, "payload should be nil")
    assert_eq(executor.iteration, 0, "iteration should be 0")
end)
run_test("build_intent_prompt includes available tools", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    local prompt = executor:build_intent_prompt("Fix bug", "Context")
    
    assert_truthy(prompt, "prompt should not be nil")
    assert_contains(prompt, "Fix bug", "prompt should contain task description")
    assert_contains(prompt, "patch", "prompt should list patch tool")
    assert_contains(prompt, "create_file", "prompt should list create_file tool")
end)
run_test("build_generate_prompt includes tool-specific hints", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    
    local prompt = executor:build_generate_prompt()
    
    assert_truthy(prompt, "prompt should not be nil")
    assert_contains(prompt, "SEARCH", "patch hint should mention SEARCH")
    assert_contains(prompt, "REPLACE", "patch hint should mention REPLACE")
end)
run_test("build_review_prompt includes tool-specific checks", function()
    local ctx = make_mock_ctx()
    local executor = multi_stage.new(ctx, "test_agent")
    
    executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
    executor.intent_raw = executor.intent.raw
    executor.payload = "payload"
    executor.last_result = "result"
    
    local prompt = executor:build_review_prompt()
    
    assert_truthy(prompt, "prompt should not be nil")
    assert_contains(prompt, "SEARCH", "patch checks should mention SEARCH")
    assert_contains(prompt, "zero-op", "patch checks should mention zero-op")
end)
-- ============================================================
-- Summary
-- ============================================================
print("\n" .. string.rep("=", 50))
print(string.format("RESULTS: %d/%d tests passed", pass_count, pass_count + fail_count))
if fail_count > 0 then
    print("\nFailures:")
    for _, f in ipairs(failures) do
        print(string.format("  - %s: %s", f.name, f.error))
    end
end
print(string.rep("=", 50))
os.exit(fail_count > 0 and 1 or 0)
