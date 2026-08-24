local multi_stage = require("multi_stage_executor")
local utils = require("utils")
local registry = require("tool_registry")
require("tools").init(nil)
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
describe("multi_stage_executor - Failure Path & Recovery", function()
    it("feed_execution_result handles FAILURE signal without crashing (regression)", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"
        executor.file_path = "src/main.c"
        executor.state = multi_stage.STATES.COMMAND_READY
        executor.iteration = 1
        local result = executor:feed_execution_result({ output = "[PATCH FAILED]: No match found", signal = "FAILURE" })
        assert.equals(result.stage, "generate", "should retry generation on failure")
        assert.equals(executor.state, multi_stage.STATES.REVISING, "state should be REVISING")
        assert.equals(executor.tool_failures["patch"], 1, "tool_failures should track patch failure count")
    end)
    it("multiple failures increment tool_failures counter", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent", { max_iterations = 5 })
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "payload"
        executor.file_path = "src/main.c"
        executor.state = multi_stage.STATES.COMMAND_READY
        executor.iteration = 1
        local r1 = executor:feed_execution_result({ output = "[PATCH FAILED]: err1", signal = "FAILURE" })
        assert.equals(r1.stage, "generate")
        assert.equals(executor.tool_failures["patch"], 1)
        executor.state = multi_stage.STATES.COMMAND_READY
        executor.iteration = 2
        local r2 = executor:feed_execution_result({ output = "[PATCH FAILED]: err2", signal = "FAILURE" })
        assert.equals(r2.stage, "generate")
        assert.equals(executor.tool_failures["patch"], 2)
        local prompt = executor:build_generate_prompt()
        assert.truthy(prompt:find("FEEDBACK", 1, true), "generate prompt should include feedback after 2+ failures")
        assert.truthy(prompt:find("failed", 1, true), "feedback should mention failure count")
    end)
    it("failure at max_iterations does not retry generation", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent", { max_iterations = 1 })
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "payload"
        executor.file_path = "src/main.c"
        executor.state = multi_stage.STATES.COMMAND_READY
        executor.iteration = 1
        local result = executor:feed_execution_result({ output = "[PATCH FAILED]: error", signal = "FAILURE" })
        assert.equals(result.stage, "review", "at max iterations, failure should go to review not retry")
    end)
    it("_merge_correction appends revision block to intent_raw", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent_raw = "GOAL: test\nTOOL: patch"
        executor.iteration = 1
        local merged = executor:_merge_correction("Fix the indentation")
        assert.truthy(merged:find("REVISION", 1, true), "should contain REVISION tag")
        assert.truthy(merged:find("Fix the indentation", 1, true), "should contain the correction text")
        assert.equals(#executor.corrections, 1, "corrections table should have 1 entry")
    end)
    it("_merge_correction summarizes when corrections exceed 3", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        executor.intent_raw = "GOAL: test\nTOOL: patch"
        executor.iteration = 4
        executor.corrections = { "fix1", "fix2", "fix3" }
        local merged = executor:_merge_correction("fix4")
        assert.truthy(merged:find("Accumulated", 1, true), "should contain accumulated summary for old corrections")
        assert.truthy(merged:find("fix4", 1, true), "should contain latest correction in full")
    end)
    it("estimate_complexity classifies .md + small hint as simple", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local result = executor:start_task_with_intent(
            "Update readme", "Context", "create_file", "small update to title", "Title changed", "README.md"
        )
        assert.equals(executor.max_iterations, 1, "simple task should limit to 1 iteration")
    end)
    it("estimate_complexity classifies shell as complex", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent")
        local result = executor:start_task_with_intent(
            "Run tests", "Context", "shell", "run all tests", "tests pass"
        )
        assert.is_true(executor.max_iterations > 1, "complex task should allow multiple iterations")
    end)
    it("save_state and load_state preserve executor state", function()
        local ctx = make_mock_ctx()
        ctx.config.PROJECT_ROOT = "/tmp/test_ms_state"
        os.execute("mkdir -p /tmp/test_ms_state/.e-va-conf")
        local executor = multi_stage.new(ctx, "test_agent")
        executor.task = "Test task"
        executor.intent_raw = "GOAL: test\nTOOL: patch"
        executor.payload = "some payload"
        executor.state = multi_stage.STATES.COMMAND_READY
        executor.iteration = 2
        executor.total_tokens_used = 500
        executor.file_path = "src/test.lua"
        executor:save_state()
        local executor2 = multi_stage.new(ctx, "test_agent")
        local ok = executor2:load_state()
        assert.is_true(ok, "load_state should succeed")
        assert.equals(executor2.task, "Test task")
        assert.equals(executor2.iteration, 2)
        assert.equals(executor2.total_tokens_used, 500)
        assert.equals(executor2.file_path, "src/test.lua")
        os.execute("rm -rf /tmp/test_ms_state")
    end)
    it("feed_execution_result detects [ERROR] in output string as failure", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent", { max_iterations = 3 })
        executor.intent = { TOOL = "shell", raw = "GOAL: test\nTOOL: shell" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "make build"
        executor.state = multi_stage.STATES.COMMAND_READY
        executor.iteration = 1
        local result = executor:feed_execution_result({ output = "[ERROR]: build failed", signal = nil })
        assert.equals(result.stage, "generate", "should retry on [ERROR] in output")
        assert.equals(executor.tool_failures["shell"], 1)
    end)
    it("feed_execution_result detects [DISK ERROR] as failure", function()
        local ctx = make_mock_ctx()
        local executor = multi_stage.new(ctx, "test_agent", { max_iterations = 3 })
        executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
        executor.intent_raw = executor.intent.raw
        executor.payload = "payload"
        executor.file_path = "src/main.c"
        executor.state = multi_stage.STATES.COMMAND_READY
        executor.iteration = 1
        local result = executor:feed_execution_result({ output = "[DISK ERROR]: permission denied", signal = nil })
        assert.equals(result.stage, "generate", "should retry on [DISK ERROR]")
        assert.equals(executor.tool_failures["patch"], 1)
    end)
end)
