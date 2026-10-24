local patcher = require("patcher")
local multi_stage = require("multi_stage_executor")
local utils = require("utils")
local registry = require("tool_registry")
require("tools").init(nil)
-- Helper: create a mock context
local function make_mock_ctx()
    local ctx = {
        config = {
            PROJECT_ROOT = "/tmp/test_project",
            AGENTS = {
                test_agent = {
                    allowed_tools = {"patch", "create_file", "shell", "read_file", "delegate_plan"}
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
-- ============================================================
-- Tests for patcher.lua
-- ============================================================
describe("patcher.lua", function()
    -- NOTE: generate_unified_diff has a known bug where fuzzy_line_eq is called
    -- before it's defined (forward reference issue at line 37). The function is
    -- defined as local at line 122. These tests document expected behavior once fixed.
    it("apply_patch returns 4 values on success (KNOWN BUG: fuzzy_line_eq forward ref)", function()
        local content = "line1\nline2\nline3"
        local patch = [[<<<<<<< SEARCH
line2
=======
line2_modified
>>>>>>> REPLACE]]
        local ok, new_content, count, diff_str = patcher.apply_patch(content, patch)
        assert.is_true(ok)
        assert.truthy(new_content, "should return new content")
        assert.truthy(count, "should return change count")
        assert.is_true(type(diff_str) == "string", "should return diff string (4th value)")
    end)
    it("apply_patch correctly modifies content (KNOWN BUG: fuzzy_line_eq forward ref)", function()
        local content = "line1\nline2\nline3"
        local patch = [[<<<<<<< SEARCH
line2
=======
line2_modified
>>>>>>> REPLACE]]
        local ok, new_content = patcher.apply_patch(content, patch)
        assert.is_true(ok, "patch should succeed")
        assert.truthy(new_content:find("line2_modified", 1, true), "content should contain modified line")
    end)
    it("apply_patch returns false for invalid blocks (no SEARCH)", function()
        local content = "some content"
        local patch = "just some random text"
        local ok, err = patcher.apply_patch(content, patch)
        assert.is_false(ok, "should return false for invalid patch")
        assert.truthy(err, "should return error message")
    end)
    it("apply_patch returns false for empty SEARCH block", function()
        local content = "some content"
        local patch = [[<<<<<<< SEARCH
=======
replacement
>>>>>>> REPLACE]]
        local ok, err = patcher.apply_patch(content, patch)
        assert.is_false(ok, "should return false for empty SEARCH block")
        assert.truthy(err, "should return error message")
    end)
    it("apply_patch returns false for identical SEARCH and REPLACE", function()
        local content = "line1\nline2\nline3"
        local patch = [[<<<<<<< SEARCH
line2
=======
line2
>>>>>>> REPLACE]]
        local ok, err = patcher.apply_patch(content, patch)
        assert.is_false(ok, "should return false for identical SEARCH/REPLACE")
        assert.truthy(err, "should return error message")
    end)
    it("apply_patch handles multiple SEARCH/REPLACE blocks (KNOWN BUG: fuzzy_line_eq forward ref)", function()
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
        assert.is_true(ok, "multiple patches should succeed")
        assert.truthy(new_content:find("AAA", 1, true), "should replace aaa")
        assert.truthy(new_content:find("CCC", 1, true), "should replace ccc")
        assert.equals(count, 2, "should report 2 changes")
    end)
    it("apply_patch generates unified diff as 4th return value (KNOWN BUG: fuzzy_line_eq forward ref)", function()
        local content = "line1\nline2\nline3"
        local patch = [[<<<<<<< SEARCH
line2
=======
line2_modified
>>>>>>> REPLACE]]
        local ok, new_content, count, diff_str = patcher.apply_patch(content, patch)
        assert.is_true(ok, "patch should succeed")
        assert.is_true(type(diff_str) == "string", "diff_str should be a string")
        assert.is_true(#diff_str > 0, "diff_str should not be empty")
        assert.truthy(diff_str:find("---", 1, true), "diff should contain --- header")
        assert.truthy(diff_str:find("+++", 1, true), "diff should contain +++ header")
    end)
end)
-- ============================================================
-- Tests for multi_stage_executor.lua - Intent Parsing
-- ============================================================
describe("multi_stage_executor.lua - Intent Parsing", function()
    it("parse_intent extracts fields from valid INTENT block", function()
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
        assert.truthy(intent, "should parse intent")
        assert.falsy(err, "should have no error")
        assert.truthy(intent.GOAL:find("bug", 1, true), "GOAL should contain 'bug'")
        assert.equals(intent.TOOL, "patch", "TOOL should be 'patch'")
    end)
    it("parse_intent rejects missing INTENT block", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local intent, err = executor:parse_intent("Just some text without tags")
        assert.falsy(intent, "should return nil intent")
        assert.truthy(err, "should return error")
    end)
    it("parse_intent rejects missing GOAL field", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local intent, err = executor:parse_intent([[
<INTENT>
TOOL: patch
</INTENT>
]])
        assert.falsy(intent, "should return nil intent")
        assert.truthy(err, "should return error about missing GOAL")
    end)
    it("parse_intent rejects missing TOOL field", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local intent, err = executor:parse_intent([[
<INTENT>
GOAL: Do something
</INTENT>
]])
        assert.falsy(intent, "should return nil intent")
        assert.truthy(err, "should return error about missing TOOL")
    end)
    it("parse_intent rejects TOOL: NONE", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local intent, err = executor:parse_intent([[
<INTENT>
GOAL: Do something
TOOL: NONE
</INTENT>
]])
        assert.falsy(intent, "should return nil intent")
        assert.truthy(err, "should return error about NONE tool")
    end)
end)
-- ============================================================
-- Tests for multi_stage_executor.lua - Review Parsing
-- ============================================================
describe("multi_stage_executor.lua - Review Parsing", function()
    it("parse_review extracts APPROVE verdict", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local review, err = executor:parse_review([[
<REVIEW>
VERDICT: APPROVE
CHECKLIST:
- [ ] Criteria 1: PASS
</REVIEW>
]])
        assert.truthy(review, "should parse review")
        assert.falsy(err, "should have no error")
        assert.equals(review.verdict, "APPROVE", "verdict should be APPROVE")
        assert.falsy(review.correction, "APPROVE should have no correction")
    end)
    it("parse_review extracts REVISE verdict with correction", function()
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
        assert.truthy(review, "should parse review")
        assert.falsy(err, "should have no error")
        assert.equals(review.verdict, "REVISE", "verdict should be REVISE")
        assert.truthy(review.correction, "REVISE should have correction")
        assert.truthy(review.correction:find("indentation", 1, true), "correction should mention indentation")
    end)
    it("parse_review rejects missing VERDICT", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local review, err = executor:parse_review([[
<REVIEW>
CHECKLIST:
- [ ] Something
</REVIEW>
]])
        assert.falsy(review, "should return nil review")
        assert.truthy(err, "should return error about missing VERDICT")
    end)
    it("parse_review rejects invalid VERDICT", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local review, err = executor:parse_review([[
<REVIEW>
VERDICT: MAYBE
</REVIEW>
]])
        assert.falsy(review, "should return nil review")
        assert.truthy(err, "should return error about invalid VERDICT")
    end)
    it("parse_review rejects REVISE without CORRECTION", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local review, err = executor:parse_review([[
<REVIEW>
VERDICT: REVISE
</REVIEW>
]])
        assert.falsy(review, "should return nil review")
        assert.truthy(err, "should return error about missing CORRECTION")
    end)
end)
-- ============================================================
-- Tests for multi_stage_executor.lua - Execution Result Handling
-- ============================================================
describe("multi_stage_executor.lua - Execution Result Handling", function()
    it("feed_execution_result extracts output.output from table result", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "test_payload"
        executor.state = multi_stage.STATES.COMMAND_READY
        local result = executor:feed_execution_result({ output = "Patch applied successfully", signal = "MUTATION_SUCCESS" })
        assert.equals(result.stage, "review", "should transition to review stage")
        assert.truthy(executor.last_result, "should store last_result")
        assert.truthy(executor.last_result:find("Patch applied successfully", 1, true), "last_result should contain output string")
        assert.truthy(executor.last_result:find("MUTATION_SUCCESS", 1, true), "last_result should contain signal")
    end)
    it("feed_execution_result handles string result", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "shell", raw = "GOAL: test\nTOOL: shell" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "echo hello"
        executor.state = multi_stage.STATES.COMMAND_READY
        local result = executor:feed_execution_result("Command output here")
        assert.equals(result.stage, "review", "should transition to review stage")
        assert.truthy(executor.last_result:find("Command output here", 1, true), "last_result should contain string output")
    end)
    it("feed_execution_result does NOT enrich patch result with full file content", function()
        local ctx = make_mock_ctx()
        ctx.knowledge_base["src/main.c"] = "int main() { return 0; }\n"
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"
        executor.state = multi_stage.STATES.COMMAND_READY
        local result = executor:feed_execution_result({ output = "Applied 1 patch block(s) to src/main.c" })
        assert.equals(result.stage, "review", "should transition to review stage")
        assert.truthy(executor.last_result:find("Applied 1 patch block", 1, true), "should contain success message")
        assert.falsy(executor.last_result:find("<file_content_after_patch", 1, true), "should NOT inject full file content")
    end)
end)
-- ============================================================
-- Tests for multi_stage_executor.lua - Task Lifecycle
-- ============================================================
describe("multi_stage_executor.lua - Task Lifecycle", function()
    it("start_task_with_intent skips intent phase", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local result = executor:start_task_with_intent(
            "Fix the bug",
            "Project context",
            "patch",
            "Replace buffer check",
            "Buffer overflow eliminated"
        )
        assert.equals(result.stage, "generate", "should skip to generate stage")
        assert.equals(executor.state, multi_stage.STATES.INTENT_READY, "state should be INTENT_READY")
        assert.equals(executor.intent.TOOL, "patch", "intent tool should be patch")
    end)
    it("start_task_with_intent rejects unknown tool", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local result = executor:start_task_with_intent(
            "Task",
            "Context",
            "nonexistent_tool",
            "Hint",
            "Criteria"
        )
        assert.equals(result.stage, "error", "should return error stage")
        assert.truthy(result.message:find("unknown tool", 1, true), "error should mention unknown tool")
    end)
    it("start_task_with_intent rejects empty tool name", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local result = executor:start_task_with_intent(
            "Task",
            "Context",
            "",
            "Hint",
            "Criteria"
        )
        assert.equals(result.stage, "error", "should return error stage")
        assert.truthy(result.message:find("empty", 1, true), "error should mention empty tool")
    end)
    it("start_task begins with intent draft stage", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local result = executor:start_task("Fix the bug", "Project context")
        assert.equals(result.stage, "intent", "should start with intent stage")
        assert.equals(executor.state, multi_stage.STATES.INTENT_DRAFT, "state should be INTENT_DRAFT")
    end)
    it("feed_response transitions from INTENT_DRAFT to INTENT_READY", function()
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
        assert.equals(result.stage, "generate", "should transition to generate stage")
        assert.equals(executor.state, multi_stage.STATES.INTENT_READY, "state should be INTENT_READY")
    end)
    it("feed_response transitions from INTENT_READY to COMMAND_READY", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Fix bug", "Context", "patch", "Replace check", "No overflow"
        )
        local result = executor:feed_response([[src/main.c
<<<<<<< SEARCH
new_code
=======
new_code
>>>>>>> REPLACE]])
        assert.equals(result.stage, "execute", "should transition to execute stage")
        assert.equals(executor.state, multi_stage.STATES.COMMAND_READY, "state should be COMMAND_READY")
        assert.truthy(result.payload:find("SEARCH", 1, true), "payload should contain SEARCH block")
    end)
end)
-- ============================================================
-- Tests for multi_stage_executor.lua - Safety Guards
-- ============================================================
describe("multi_stage_executor.lua - Safety Guards", function()
    it("max_iterations enforcement causes error", function()
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
        assert.equals(result.stage, "error", "should return error at max iterations")
        assert.truthy(result.message:find(tostring(executor.max_iterations), 1, true), "error should mention iteration count")
    end)
    it("token budget force-approval prevents runaway consumption", function()
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
        assert.equals(result.stage, "done", "should force-approve due to token budget")
        assert.truthy(result.forced_approval, "should indicate forced approval")
    end)
    it("review parse failure with APPROVE inferred auto-approves", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "payload"
        executor.last_result = "result"
        executor.state = multi_stage.STATES.REVIEWING
        executor.iteration = 1
        local result = executor:feed_response("I APPROVE this change, looks good!")
        assert.equals(result.stage, "done", "should auto-approve when APPROVE is inferred")
    end)
    it("review parse failure with REVISE inferred enters revision", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "payload"
        executor.last_result = "result"
        executor.state = multi_stage.STATES.REVIEWING
        executor.iteration = 1
        local result = executor:feed_response("This needs REVISE, there's an ERROR")
        assert.equals(result.stage, "generate", "should enter revision when REVISE is inferred")
    end)
    it("reset clears all state", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task("Task", "Context")
        assert.equals(executor.state, multi_stage.STATES.INTENT_DRAFT, "should be in INTENT_DRAFT")
        executor:reset()
        assert.equals(executor.state, multi_stage.STATES.IDLE, "should be IDLE after reset")
        assert.falsy(executor.task, "task should be nil")
        assert.falsy(executor.intent, "intent should be nil")
        assert.falsy(executor.payload, "payload should be nil")
        assert.equals(executor.iteration, 0, "iteration should be 0")
    end)
end)
-- ============================================================
-- Tests for multi_stage_executor.lua - Prompt Building (Manifest-Based)
-- ============================================================
describe("multi_stage_executor.lua - Prompt Building", function()
    it("build_intent_prompt includes available tools", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local prompt = executor:build_intent_prompt("Fix bug", "Context")
        assert.truthy(prompt, "prompt should not be nil")
        assert.truthy(prompt:find("Fix bug", 1, true), "prompt should contain task description")
        assert.truthy(prompt:find("patch", 1, true), "prompt should list patch tool")
        assert.truthy(prompt:find("create_file", 1, true), "prompt should list create_file tool")
    end)
    it("build_generate_prompt includes manifest.generate_hint for patch", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        local prompt = executor:build_generate_prompt()
        assert.truthy(prompt, "prompt should not be nil")
        -- Manifest generate_hint for patch includes SEARCH/REPLACE format docs
        assert.truthy(prompt:find("SEARCH", 1, true), "patch hint should mention SEARCH")
        assert.truthy(prompt:find("REPLACE", 1, true), "patch hint should mention REPLACE")
    end)
    it("build_review_prompt includes manifest.review_checks for patch", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "payload"
        executor.last_result = "result"
        local prompt = executor:build_review_prompt()
        assert.truthy(prompt, "prompt should not be nil")
        -- Manifest review_checks for patch includes zero-op check
        assert.truthy(prompt:find("SEARCH", 1, true), "patch checks should mention SEARCH")
        assert.truthy(prompt:find("zero-op", 1, true), "patch checks should mention zero-op")
    end)
    it("build_generate_prompt does NOT include SEARCH/REPLACE hints for non-patch tools", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "shell", raw = "GOAL: test\nTOOL: shell" }
        executor.intent_raw = executor.intent.raw
        local prompt = executor:build_generate_prompt()
        assert.truthy(prompt, "prompt should not be nil")
        -- shell tool has no generate_hint, so no SEARCH/REPLACE should appear
        assert.falsy(prompt:find("SEARCH", 1, true), "shell hint should NOT mention SEARCH")
    end)
end)
-- ============================================================
-- Tests for multi_stage_executor.lua - File Path Prepending
-- ============================================================
describe("multi_stage_executor.lua - File Path Prepending", function()
    it("start_task_with_intent produces execute result with file_path prepended for patch", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        -- Start with intent (skips intent phase)
        local result = executor:start_task_with_intent(
            "Fix bug", "Context", "patch", "Replace check", "No overflow", "src/main.c"
        )
        assert.equals(result.stage, "generate", "should skip to generate stage")
        assert.equals(executor.file_path, "src/main.c", "file_path should be stored")
        -- Now feed a payload (simulate generate phase)
        local patch_payload = "<<<<<<< SEARCH\nold_code\n=======\nnew_code\n>>>>>>> REPLACE"
        result = executor:feed_response(patch_payload)
        assert.equals(result.stage, "execute", "should transition to execute stage")
        assert.truthy(result.payload:find("src/main.c", 1, true), "effective_payload should prepend file path")
        assert.truthy(result.payload:find("SEARCH", 1, true), "effective_payload should contain SEARCH block")
    end)
    it("start_task_with_intent produces execute result with file_path prepended for create_file", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local result = executor:start_task_with_intent(
            "Create module", "Context", "create_file", "New lua module", "Module loads", "src/new_mod.lua"
        )
        assert.equals(result.stage, "generate", "should skip to generate stage")
        assert.equals(executor.file_path, "src/new_mod.lua", "file_path should be stored")
        -- Feed file content payload
        result = executor:feed_response("local M = {}\nreturn M")
        assert.equals(result.stage, "execute", "should transition to execute stage")
        assert.truthy(result.payload:find("src/new_mod.lua", 1, true), "effective_payload should prepend file path")
        assert.truthy(result.payload:find("local M", 1, true), "effective_payload should contain file content")
    end)
    it("payload validation passes for valid patch SEARCH/REPLACE blocks", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Fix bug", "Context", "patch", "Replace check", "No overflow", "src/main.c"
        )
        -- Valid patch payload
        local patch_payload = "<<<<<<< SEARCH\nold_code\n=======\nnew_code\n>>>>>>> REPLACE"
        local result = executor:feed_response(patch_payload)
        assert.equals(result.stage, "execute", "valid patch payload should pass validation")
    end)
    it("payload validation rejects patch without SEARCH marker", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Fix bug", "Context", "patch", "Replace check", "No overflow", "src/main.c"
        )
        -- Invalid: no SEARCH marker
        local result = executor:feed_response("just some random text without search blocks")
        -- Should either error or request regeneration (validation failure)
        assert.is_true(result.stage == "error" or result.stage == "generate", "should fail validation or retry")
    end)
    it("effective_payload correctly prepends file_path for patch tool", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Fix bug", "Context", "patch", "Replace check", "No overflow", "src/main.c"
        )
        local patch_payload = "<<<<<<< SEARCH\nline1\n=======\nline1_new\n>>>>>>> REPLACE"
        local result = executor:feed_response(patch_payload)
        assert.equals(result.stage, "execute", "should reach execute stage")
        -- Verify the payload starts with the file path
        local first_line = result.payload:match("^[^\r\n]+")
        assert.equals(first_line, "src/main.c", "first line of effective_payload should be file path")
    end)
end)
-- ============================================================
-- NEW TESTS: Manifest-Based Architecture
-- ============================================================
describe("multi_stage_executor.lua - Manifest Integration", function()
    it("manifest.validate_payload is called during payload validation", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Fix bug", "Context", "patch", "Replace check", "No overflow", "src/main.c"
        )
        -- Valid patch payload should pass manifest.validate_payload
        local patch_payload = "<<<<<<< SEARCH\nold_code\n=======\nnew_code\n>>>>>>> REPLACE"
        local result = executor:feed_response(patch_payload)
        assert.equals(result.stage, "execute", "valid payload should pass manifest validation")
    end)
    it("manifest.validate_payload rejection triggers regeneration", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Fix bug", "Context", "patch", "Replace check", "No overflow", "src/main.c"
        )
        -- Invalid: empty payload should fail manifest.validate_payload
        local result = executor:feed_response("")
        -- Should trigger regeneration or error
        assert.is_true(result.stage == "generate" or result.stage == "error", "invalid payload should fail validation")
    end)
    it("patch tool no longer has enrich_result (diff-only output)", function()
        local ctx = make_mock_ctx()
        ctx.knowledge_base["src/main.c"] = "int main() { return 0; }\n"
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"
        executor.file_path = "src/main.c"
        executor.state = multi_stage.STATES.COMMAND_READY
        local result = executor:feed_execution_result({ output = "Applied 1 patch block(s) to src/main.c" })
        assert.equals(result.stage, "review", "should transition to review stage")
        -- enrich_result removed: no full-file injection
        assert.falsy(executor.last_result:find("<file_content_after_patch", 1, true), "should NOT inject file content")
    end)
    it("manifest.generate_hint is injected into generate prompt", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        local prompt = executor:build_generate_prompt()
        -- Patch manifest has generate_hint with SEARCH/REPLACE format docs
        assert.truthy(prompt:find("SEARCH", 1, true), "generate prompt should include manifest.generate_hint")
        assert.truthy(prompt:find("REPLACE", 1, true), "generate prompt should include REPLACE docs")
    end)
    it("manifest.review_checks are injected into review prompt", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "payload"
        executor.last_result = "result"
        local prompt = executor:build_review_prompt()
        -- Patch manifest has review_checks with zero-op check
        assert.truthy(prompt:find("zero-op", 1, true), "review prompt should include manifest.review_checks")
    end)
    it("manifest.intent_guideline is included in intent prompt", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local prompt = executor:build_intent_prompt("Fix bug", "Context")
        -- Patch manifest has intent_guideline
        assert.truthy(prompt:find("patch", 1, true), "intent prompt should mention patch tool")
        -- Guidelines section should exist
        assert.truthy(prompt:find("GUIDELINES", 1, true) or prompt:find("guideline", 1, true), "intent prompt should include guidelines")
    end)
    it("Dynamic Tool Registration: manifest.is_mutation controls squash behavior", function()
        -- Verify that patch tool has is_mutation=true in manifest
        local patch_tool = registry.tools["patch"]
        assert.truthy(patch_tool, "patch tool should be registered")
        assert.truthy(patch_tool.manifest, "patch tool should have manifest")
        assert.is_true(patch_tool.manifest.is_mutation == true, "patch manifest.is_mutation should be true")
        -- Verify that shell tool has is_mutation=false or no manifest
        local shell_tool = registry.tools["shell"]
        if shell_tool and shell_tool.manifest then
            assert.is_true(shell_tool.manifest.is_mutation == false, "shell manifest.is_mutation should be false")
        end
    end)
    it("Lazy Context Loading: intent prompt does NOT contain SEARCH/REPLACE", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local prompt = executor:build_intent_prompt("Fix bug", "Context")
        -- Intent prompt should NOT contain SEARCH/REPLACE format docs
        -- Those belong in the generate phase, not intent phase
        assert.falsy(prompt:find("<<<<<<< SEARCH", 1, true), "intent prompt should NOT contain SEARCH markers")
        assert.falsy(prompt:find(">>>>>>> REPLACE", 1, true), "intent prompt should NOT contain REPLACE markers")
    end)
end)