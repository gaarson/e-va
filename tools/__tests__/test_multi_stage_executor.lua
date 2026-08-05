local utils = require("utils")
local tool_registry = require("tool_registry")
local logger = require("logger")
require("tools").init(nil)
local multi_stage = require("multi_stage_executor")

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

-- ============================================================================
-- TEST GROUP 1: feed_execution_result correctly extracts output string
-- ============================================================================
describe("GROUP 1: feed_execution_result output extraction", function()
    it("Table result with output field returns review stage", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result({ output = "Patch applied successfully", signal = "MUTATION_SUCCESS" })
        assert.equals(result.stage, "review", "Returns review stage")
        assert.truthy(exec.last_result:find("Patch applied successfully"), "Contains output string")
        assert.truthy(exec.last_result:find("MUTATION_SUCCESS"), "Contains signal")
    end)

    it("String result returns review stage", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "shell", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result("Command output here")
        assert.equals(result.stage, "review", "Returns review stage for string input")
        assert.truthy(exec.last_result:find("Command output here"), "Contains string output")
    end)

    it("Nil/empty result handles nil output", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "shell", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result(nil)
        assert.truthy(exec.last_result:find("empty output"), "Handles nil output")
    end)

    it("Empty string result handles empty string output", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "shell", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result("")
        assert.truthy(exec.last_result:find("empty output"), "Handles empty string output")
    end)

    it("Table with only signal, no output contains signal", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "shell", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result({ signal = "PIPELINE_NEXT_STAGE" })
        assert.truthy(exec.last_result:find("PIPELINE_NEXT_STAGE"), "Contains signal when no output")
    end)
end)

-- ============================================================================
-- TEST GROUP 2: Patch execution result includes file content for review
-- ============================================================================
describe("GROUP 2: Patch execution result enrichment", function()
    it("Patch tool includes file content after patching", function()
        local ctx = mock_ctx()
        ctx.knowledge_base["src/test.lua"] = "local x = 1\nlocal y = 2\nlocal z = 3\n"
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.payload = "src/test.lua\n<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 10\n>>>>>>> REPLACE"
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result({ output = "[SUCCESS]: Applied 1 patch block(s) to src/test.lua.", signal = "MUTATION_SUCCESS" })
        assert.truthy(exec.last_result:find("<file_content_after_patch"), "Includes file_content_after_patch tag")
        assert.truthy(exec.last_result:find("local x = 1"), "Contains original file content")
    end)

    it("Non-patch tool does NOT include file content enrichment", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "shell", raw = "test" }
        exec.payload = "echo hello"
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result({ output = "hello" })
        assert.falsy(exec.last_result:find("<file_content_after_patch"), "Non-patch tools don't include file content enrichment")
    end)
end)

-- ============================================================================
-- TEST GROUP 3: Intent parsing with various formats
-- ============================================================================
describe("GROUP 3: Intent parsing", function()
    it("Parses valid intent with all fields", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local intent, err = exec:parse_intent([[
<INTENT>
GOAL: Fix the bug in parser.c
TOOL: patch
PAYLOAD_HINT: Replace buffer overflow check with bounds validation
SUCCESS_CRITERIA: The patch applies cleanly and the test passes
</INTENT>
    ]])
        assert.truthy(intent, "Parses valid intent")
        assert.equals(intent.TOOL, "patch", "Extracts tool name")
        assert.truthy(intent.GOAL:find("bug"), "Extracts goal")
        assert.truthy(intent.PAYLOAD_HINT:find("buffer"), "Extracts payload hint")
    end)

    it("Parses intent with extra whitespace", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local intent, err = exec:parse_intent([[
<INTENT>
  GOAL:   Trim whitespace test  
  TOOL:   shell  
  PAYLOAD_HINT:   Echo test  
  SUCCESS_CRITERIA:   Output matches  
</INTENT>
    ]])
        assert.truthy(intent, "Parses intent with extra whitespace")
        assert.equals(intent.TOOL, "shell", "Trims tool name")
    end)

    it("Rejects intent missing GOAL", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local intent, err = exec:parse_intent([[
<INTENT>
TOOL: patch
PAYLOAD_HINT: Some hint
SUCCESS_CRITERIA: Works
</INTENT>
    ]])
        assert.falsy(intent, "Rejects intent missing GOAL")
        assert.truthy(err:find("GOAL"), "Error mentions GOAL")
    end)

    it("Rejects intent missing TOOL", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local intent, err = exec:parse_intent([[
<INTENT>
GOAL: Do something
PAYLOAD_HINT: Some hint
SUCCESS_CRITERIA: Works
</INTENT>
    ]])
        assert.falsy(intent, "Rejects intent missing TOOL")
        assert.truthy(err:find("TOOL"), "Error mentions TOOL")
    end)

    it("Rejects intent with unknown tool", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local intent, err = exec:parse_intent([[
<INTENT>
GOAL: Do something
TOOL: nonexistent_tool
PAYLOAD_HINT: Some hint
SUCCESS_CRITERIA: Works
</INTENT>
    ]])
        assert.falsy(intent, "Rejects intent with unknown tool")
        assert.truthy(err:find("nonexistent_tool"), "Error mentions unknown tool")
    end)

    it("Rejects TOOL: NONE", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local intent, err = exec:parse_intent([[
<INTENT>
GOAL: No tool needed
TOOL: NONE
PAYLOAD_HINT: N/A
SUCCESS_CRITERIA: N/A
</INTENT>
    ]])
        assert.falsy(intent, "Rejects TOOL: NONE")
        assert.truthy(err:find("no suitable tool"), "Error mentions no suitable tool")
    end)

    it("Rejects text without INTENT block", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local intent, err = exec:parse_intent("Just some random text without intent block")
        assert.falsy(intent, "Rejects text without INTENT block")
        assert.truthy(err:find("INTENT"), "Error mentions INTENT block")
    end)
end)

-- ============================================================================
-- TEST GROUP 4: Review parsing with APPROVE/REVISE verdicts
-- ============================================================================
describe("GROUP 4: Review parsing", function()
    it("Parses valid APPROVE review", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
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
        assert.truthy(review, "Parses valid APPROVE review")
        assert.equals(review.verdict, "APPROVE", "Verdict is APPROVE")
        assert.falsy(review.correction, "No correction for APPROVE")
    end)

    it("Parses valid REVISE review", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local review, err = exec:parse_review([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria 1: FAIL — Wrong indentation
- [ ] Criteria 2: PASS — OK
CORRECTION:
Fix the indentation in lines 5-10. Use 4 spaces instead of tabs.
</REVIEW>
    ]])
        assert.truthy(review, "Parses valid REVISE review")
        assert.equals(review.verdict, "REVISE", "Verdict is REVISE")
        assert.truthy(review.correction:find("indentation"), "Contains correction text")
    end)

    it("Rejects review missing VERDICT", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local review, err = exec:parse_review([[
<REVIEW>
CHECKLIST:
- [ ] Something: PASS
</REVIEW>
    ]])
        assert.falsy(review, "Rejects review missing VERDICT")
        assert.truthy(err:find("VERDICT"), "Error mentions VERDICT")
    end)

    it("Rejects invalid VERDICT value", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local review, err = exec:parse_review([[
<REVIEW>
VERDICT: MAYBE
CHECKLIST:
- [ ] Something: PASS
</REVIEW>
    ]])
        assert.falsy(review, "Rejects invalid VERDICT value")
        assert.truthy(err:find("Invalid VERDICT"), "Error mentions invalid VERDICT")
    end)

    it("Rejects REVISE without CORRECTION", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local review, err = exec:parse_review([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Something: FAIL
</REVIEW>
    ]])
        assert.falsy(review, "Rejects REVISE without CORRECTION")
        assert.truthy(err:find("CORRECTION"), "Error mentions CORRECTION")
    end)

    it("Parses lowercase verdict", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local review, err = exec:parse_review([[
<REVIEW>
VERDICT: approve
CHECKLIST:
- [ ] Something: PASS
</REVIEW>
    ]])
        assert.truthy(review, "Parses lowercase verdict")
        assert.equals(review.verdict, "APPROVE", "Normalizes verdict to uppercase")
    end)
end)

-- ============================================================================
-- TEST GROUP 5: Payload sanitization edge cases
-- ============================================================================
describe("GROUP 5: Payload sanitization", function()
    it("Strips markdown fences", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local result = exec:feed_response("```lua\nlocal x = 1\n```")
        assert.falsy(exec.payload:find("```"), "Strips markdown fences")
        assert.truthy(exec.payload:find("local x = 1"), "Preserves content")
    end)

    it("Strips thinking tags", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local result = exec:feed_response("\nlocal x = 1")
        assert.falsy(exec.payload:find("<thinking>"), "Strips thinking tags")
        assert.truthy(exec.payload:find("local x = 1"), "Preserves content after tags")
    end)

    it("Preserves content after preamble", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local result = exec:feed_response("here is the payload:\nlocal x = 1")
        assert.truthy(exec.payload:find("local x = 1"), "Preserves content after preamble")
    end)

    it("Strips command wrappers", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local result = exec:feed_response("||| COMMAND |||\npatch:test.lua\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE\n||| END_COMMAND |||")
        assert.falsy(exec.payload:find("||| COMMAND |||"), "Strips command wrappers")
        assert.truthy(exec.payload:find("patch:test.lua"), "Preserves payload content")
    end)

    it("Empty payload triggers validation retry or error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local result = exec:feed_response("")
        assert.truthy(result.stage == "generate" or result.stage == "error", "Empty payload triggers validation retry or error")
    end)
end)

-- ============================================================================
-- TEST GROUP 6: max_iterations enforcement
-- ============================================================================
describe("GROUP 6: max_iterations enforcement", function()
    it("Exceeds max_iterations causes error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 2 })
        exec:start_task("Test task", "")
        local step = exec:feed_response([[
<INTENT>
GOAL: Test goal
TOOL: shell
PAYLOAD_HINT: Echo test
SUCCESS_CRITERIA: Output matches
</INTENT>
    ]])
        assert.equals(step.stage, "generate", "Moves to generate after intent")
        step = exec:feed_response("echo hello")
        assert.equals(step.stage, "execute", "Moves to execute after payload")
        step = exec:feed_execution_result({ output = "hello" })
        assert.equals(step.stage, "review", "Moves to review after execution")
        step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria: FAIL — Wrong output
CORRECTION:
Use echo world instead.
</REVIEW>
    ]])
        assert.equals(step.stage, "generate", "Revise triggers regenerate")
        step = exec:feed_response("echo world")
        assert.equals(step.stage, "execute", "Moves to execute after revised payload")
        step = exec:feed_execution_result({ output = "world" })
        assert.equals(step.stage, "review", "Moves to review after execution")
        step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria: FAIL — Still wrong
CORRECTION:
Try something else.
</REVIEW>
    ]])
        assert.equals(step.stage, "error", "Exceeds max_iterations causes error")
        assert.truthy(step.message:find("Failed to satisfy intent"), "Error mentions iteration failure")
    end)
end)

-- ============================================================================
-- TEST GROUP 7: Correction merging across iterations
-- ============================================================================
describe("GROUP 7: Correction merging", function()
    it("Merges corrections across iterations", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 5 })
        exec:start_task("Test task", "")
        local step = exec:feed_response([[
<INTENT>
GOAL: Test goal
TOOL: shell
PAYLOAD_HINT: Echo test
SUCCESS_CRITERIA: Output matches
</INTENT>
    ]])
        step = exec:feed_response("echo hello")
        step = exec:feed_execution_result({ output = "hello" })
        step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION:
Correction 1: Use double quotes.
</REVIEW>
    ]])
        assert.truthy(exec.intent_raw:find("Correction 1"), "First correction merged")
        step = exec:feed_response("echo \"hello\"")
        step = exec:feed_execution_result({ output = "hello" })
        step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION:
Correction 2: Add -n flag.
</REVIEW>
    ]])
        assert.truthy(exec.intent_raw:find("Correction 2"), "Second correction merged")
        assert.truthy(exec.intent_raw:find("Correction 1"), "First correction still present")
        step = exec:feed_response("echo -n \"hello\"")
        step = exec:feed_execution_result({ output = "hello" })
        step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CORRECTION:
Correction 3: Use printf instead.
</REVIEW>
    ]])
        assert.truthy(exec.intent_raw:find("Correction 3"), "Third correction merged")
        assert.truthy(exec.intent_raw:find("Accumulated reviewer notes"), "Older corrections summarized")
    end)
end)

-- ============================================================================
-- TEST GROUP 8: start_task_with_intent flow
-- ============================================================================
describe("GROUP 8: start_task_with_intent flow", function()
    it("Valid start_task_with_intent skips intent, goes to generate", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local step = exec:start_task_with_intent(
            "Fix the bug",
            "Project context",
            "patch",
            "Replace buffer check",
            "Patch applies cleanly"
        )
        assert.equals(step.stage, "generate", "Skips intent, goes to generate")
        assert.equals(exec.intent.TOOL, "patch", "Tool is set correctly")
        assert.truthy(exec.intent.GOAL:find("Fix the bug"), "Goal is set correctly")
    end)

    it("Empty tool_name causes error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local step = exec:start_task_with_intent("Task", "Ctx", "", "Hint", "Criteria")
        assert.equals(step.stage, "error", "Empty tool_name causes error")
    end)

    it("Unknown tool_name causes error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        local step = exec:start_task_with_intent("Task", "Ctx", "nonexistent", "Hint", "Criteria")
        assert.equals(step.stage, "error", "Unknown tool_name causes error")
    end)

    it("Full flow with start_task_with_intent completes", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        local step = exec:start_task_with_intent("Task", "Ctx", "shell", "Echo test", "Output matches")
        assert.equals(step.stage, "generate", "Valid start_task_with_intent goes to generate")
        step = exec:feed_response("echo test")
        assert.equals(step.stage, "execute", "Goes to execute after payload")
        step = exec:feed_execution_result({ output = "test" })
        assert.equals(step.stage, "review", "Goes to review after execution")
        step = exec:feed_response([[
<REVIEW>
VERDICT: APPROVE
CHECKLIST:
- [ ] Output matches: PASS
CORRECTION:
None.
</REVIEW>
    ]])
        assert.equals(step.stage, "done", "Approve completes the task")
        assert.equals(step.iterations, 1, "Completed in 1 iteration")
    end)
end)

-- ============================================================================
-- TEST GROUP 9: Token budget force-approval
-- ============================================================================
describe("GROUP 9: Token budget force-approval", function()
    it("Token budget exceeded forces approval", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", {
            max_iterations = 10,
            max_tokens_per_task = 100
        })
        exec:start_task("Test task", "")
        local step = exec:feed_response([[
<INTENT>
GOAL: Test goal
TOOL: shell
PAYLOAD_HINT: Echo test
SUCCESS_CRITERIA: Output matches
</INTENT>
    ]])
        step = exec:feed_response("echo hello")
        step = exec:feed_execution_result({ output = "hello" })
        exec.total_tokens_used = 200
        step = exec:feed_response([[
<REVIEW>
VERDICT: REVISE
CHECKLIST:
- [ ] Criteria: FAIL
CORRECTION:
Something wrong.
</REVIEW>
    ]])
        assert.equals(step.stage, "done", "Token budget exceeded forces approval")
        assert.truthy(step.forced_approval, "Flagged as forced approval")
    end)
end)

-- ============================================================================
-- TEST GROUP 10: Payload validation
-- ============================================================================
describe("GROUP 10: Payload validation", function()
    it("Invalid JSON for delegate_plan triggers retry or error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "delegate_plan", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local step = exec:feed_response("not valid json")
        assert.truthy(step.stage == "generate" or step.stage == "error", "Invalid JSON for delegate_plan triggers retry or error")
    end)

    it("Missing memo for delegate_plan triggers retry or error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "delegate_plan", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local step = exec:feed_response('{ "plan": [] }')
        assert.truthy(step.stage == "generate" or step.stage == "error", "Missing memo for delegate_plan triggers retry or error")
    end)

    it("Missing SEARCH/REPLACE for patch triggers retry or error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local step = exec:feed_response("just some text without search/replace")
        assert.truthy(step.stage == "generate" or step.stage == "error", "Missing SEARCH/REPLACE for patch triggers retry or error")
    end)

    it("Empty payload for create_file triggers retry or error", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "create_file", raw = "test" }
        exec.state = multi_stage.STATES.INTENT_READY
        local step = exec:feed_response("")
        assert.truthy(step.stage == "generate" or step.stage == "error", "Empty payload for create_file triggers retry or error")
    end)
end)

-- ============================================================================
-- TEST GROUP 11: generate_unified_diff produces correct diff output
-- ============================================================================
describe("GROUP 11: generate_unified_diff", function()
    local patcher = require("patcher")

    it("Identical files produce empty diff", function()
        local old_lines = {"line 1", "line 2", "line 3"}
        local new_lines = {"line 1", "line 2", "line 3"}
        local diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
        assert.equals(diff, "", "Identical files produce empty diff")
    end)

    it("Single line change produces diff with context", function()
        local old_lines = {"line 1", "line 2", "line 3", "line 4", "line 5"}
        local new_lines = {"line 1", "line 2", "CHANGED", "line 4", "line 5"}
        local diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
        assert.truthy(diff:find("--- test.txt"), "Diff contains old filename")
        assert.truthy(diff:find("+++ test.txt"), "Diff contains new filename")
        assert.truthy(diff:find("@@"), "Diff contains hunk header")
        assert.truthy(diff:find("-line 3"), "Diff contains removed line")
        assert.truthy(diff:find("+CHANGED"), "Diff contains added line")
    end)

    it("Added lines at end", function()
        local old_lines = {"line 1", "line 2"}
        local new_lines = {"line 1", "line 2", "line 3", "line 4"}
        local diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
        assert.truthy(diff:find("+line 3"), "Diff contains added line 3")
        assert.truthy(diff:find("+line 4"), "Diff contains added line 4")
    end)

    it("Removed lines", function()
        local old_lines = {"line 1", "line 2", "line 3", "line 4"}
        local new_lines = {"line 1", "line 2"}
        local diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
        assert.truthy(diff:find("-line 3"), "Diff contains removed line 3")
        assert.truthy(diff:find("-line 4"), "Diff contains removed line 4")
    end)

    it("Empty old file", function()
        local old_lines = {}
        local new_lines = {"line 1", "line 2"}
        local diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
        assert.truthy(diff:find("+line 1"), "Diff contains added line from empty file")
    end)

    it("Empty new file", function()
        local old_lines = {"line 1", "line 2"}
        local new_lines = {}
        local diff = patcher.generate_unified_diff(old_lines, new_lines, "test.txt")
        assert.truthy(diff:find("-line 1"), "Diff contains removed line to empty file")
    end)
end)

-- ============================================================================
-- TEST GROUP 12: Patch success output contains diff block
-- ============================================================================
describe("GROUP 12: Patch success output with diff", function()
    local patcher = require("patcher")

    it("Successful patch returns diff string", function()
        local original = "line 1\nline 2\nline 3\n"
        local patch_body = "<<<<<<< SEARCH\nline 2\n=======\nCHANGED\n>>>>>>> REPLACE"
        local ok, new_content, changes, diff_str = patcher.apply_patch(original, patch_body)
        assert.truthy(ok, "Patch applies successfully")
        assert.equals(changes, 1, "One change applied")
        assert.truthy(diff_str, "Diff string is returned")
        assert.truthy(diff_str:find("-line 2"), "Diff contains removed line")
        assert.truthy(diff_str:find("+CHANGED"), "Diff contains added line")
    end)

    it("Failed patch returns error message as 2nd value", function()
        local original = "line 1\nline 2\nline 3\n"
        local patch_body = "<<<<<<< SEARCH\nNONEXISTENT\n=======\nCHANGED\n>>>>>>> REPLACE"
        local ok, new_content, changes, diff_str = patcher.apply_patch(original, patch_body)
        assert.falsy(ok, "Patch fails for nonexistent search")
        assert.truthy(new_content, "Error message is returned as 2nd value")
        assert.truthy(tostring(new_content):find("FAILED"), "Error message contains FAILED")
    end)

    it("Zero-op patch fails", function()
        local original = "line 1\nline 2\nline 3\n"
        local patch_body = "<<<<<<< SEARCH\nline 2\n=======\nline 2\n>>>>>>> REPLACE"
        local ok, new_content, changes, diff_str = patcher.apply_patch(original, patch_body)
        assert.falsy(ok, "Zero-op patch fails")
    end)
end)

-- ============================================================================
-- TEST GROUP 13: feed_execution_result handles table with output field
-- ============================================================================
describe("GROUP 13: feed_execution_result table handling", function()
    it("Table with output and signal fields", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result({
            output = "Patch applied successfully",
            signal = "MUTATION_SUCCESS"
        })
        assert.equals(result.stage, "review", "Returns review stage")
        assert.truthy(exec.last_result:find("Patch applied successfully"), "Contains output string")
        assert.truthy(exec.last_result:find("MUTATION_SUCCESS"), "Contains signal")
    end)

    it("Table with only output field", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "shell", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result({ output = "Just output" })
        assert.truthy(exec.last_result:find("Just output"), "Contains output without signal")
        assert.falsy(exec.last_result:find("SIGNAL"), "No signal when not provided")
    end)

    it("Table with nil output contains signal", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec:reset()
        exec.intent = { TOOL = "shell", raw = "test" }
        exec.state = multi_stage.STATES.COMMAND_READY
        local result = exec:feed_execution_result({ signal = "SOME_SIGNAL" })
        assert.truthy(exec.last_result:find("SOME_SIGNAL"), "Contains signal when output is nil")
    end)
end)

-- ============================================================================
-- TEST GROUP 14: Review prompt includes tool-specific checks
-- ============================================================================
describe("GROUP 14: Review prompt tool-specific checks", function()
    it("Patch review prompt mentions file_content_after_patch", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "patch", raw = "test" }
        exec.payload = "some payload"
        exec.last_result = "some result"
        local prompt = exec:build_review_prompt()
        assert.truthy(prompt:find("file_content_after_patch"), "Patch review prompt mentions file_content_after_patch")
        assert.truthy(prompt:find("SEARCH block"), "Patch review prompt mentions SEARCH blocks")
    end)

    it("create_file review prompt mentions file creation", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "create_file", raw = "test" }
        local prompt = exec:build_review_prompt()
        assert.truthy(prompt:find("file_content_after_create"), "create_file review prompt mentions file_content_after_create")
    end)

    it("delegate_plan review prompt mentions JSON and memo", function()
        local ctx = mock_ctx()
        local exec = multi_stage.new(ctx, "TEST_AGENT", { max_iterations = 3 })
        exec.intent = { TOOL = "delegate_plan", raw = "test" }
        local prompt = exec:build_review_prompt()
        assert.truthy(prompt:find("JSON"), "delegate_plan review prompt mentions JSON")
        assert.truthy(prompt:find("memo"), "delegate_plan review prompt mentions memo")
    end)
end)
