-- agent/__tests__/test_multi_stage_kv_cache.lua
-- Tests for the KV-cache optimized fork-and-rollback pattern in run_multi_stage_loop.
-- Verifies: prefix stability, checkpoint/rollback, tail growth, summary messages.
local multi_stage = require("agent.multi_stage")
-- ============================================================
-- Mock infrastructure
-- ============================================================
local function make_mock_llm(scripted_responses)
    local M = {}
    M.calls = {}
    M.call_count = 0
    local idx = 1
    function M.send_request(agent_cfg, messages, opts)
        M.call_count = M.call_count + 1
        local recorded = {}
        for i, msg in ipairs(messages) do
            recorded[i] = { role = msg.role, content = msg.content }
        end
        table.insert(M.calls, recorded)
        local response_content = scripted_responses[idx] or "DEFAULT_RESPONSE"
        idx = idx + 1
        return {
            choices = { [1] = { message = { content = response_content } } }
        }, nil
    end
    return M
end
local function make_mock_ctx(initial_history)
    local ctx = {
        history = {},
        file_tree = "file1.lua\nfile2.lua",
        config = {
            PROJECT_ROOT = "/tmp/test_kv_cache",
            AGENTS = { test_agent = { allowed_tools = {"patch", "create_file", "shell"} } },
            LIMITS = { MAX_CONTEXT = 128000, RESERVED_OUTPUT = 4096, SYSTEM_PROMPT_ESTIMATE = 2048, CHARS_PER_TOKEN = 3.5 },
        },
    }
    for i, msg in ipairs(initial_history or {}) do
        ctx.history.test_agent = ctx.history.test_agent or {}
        table.insert(ctx.history.test_agent, { role = msg.role, content = msg.content })
    end
    ctx.build_context_call_count = 0
    function ctx:build_context(agent_name, agent_cfg, available_tokens)
        self.build_context_call_count = self.build_context_call_count + 1
        local history = self.history[agent_name] or {}
        local messages = { { role = "system", content = "[SYSTEM PROMPT - FIXED PREFIX]" } }
        for i, msg in ipairs(history) do
            table.insert(messages, { role = msg.role, content = msg.content })
        end
        return { messages = messages }
    end
    function ctx:add_message(agent_name, role, content)
        self.history[agent_name] = self.history[agent_name] or {}
        table.insert(self.history[agent_name], { role = role, content = content })
    end
    return ctx
end
local function make_deps(mock_llm)
    local logger = { info = function(_, ...) end, warn = function(_, ...) end, error = function(_, ...) end }
    local utils = {
        trim = function(s) if not s then return "" end return s:gsub("^%s*(.-)%s*$", "%1") end,
        sanitize_for_json = function(s) return s or "" end,
        stream_token_printer = function() return {} end,
        flush_stream_buffer = function() end,
    }
    local registry = {
        execute = function(cmd, ctx, agent_name)
            return { output = "[TOOL OUTPUT] executed: " .. cmd, signal = "SUCCESS" }
        end,
    }
    return {
        logger = logger, utils = utils, llm = mock_llm, registry = registry,
        context_optimizer = { shrink_max_tokens = function() return 1024 end },
        optimizer = { generate_continuation_prompt = function() return nil end },
    }
end
local function make_mock_executor_full_flow()
    local M = {}
    M.intent = { TOOL = "patch", GOAL = "test goal" }
    M.save_state_calls = 0
    function M:start_task(task, project_context)
        return { stage = "intent", prompt = "[INTENT PROMPT] Plan the task: " .. task }
    end
    function M:start_task_with_intent(task, project_context, tool_name, payload_hint, success_criteria, file_path)
        self.intent = { TOOL = tool_name, GOAL = task }
        return { stage = "generate", prompt = "[GENERATE PROMPT] Generate payload for: " .. tool_name }
    end
    function M:feed_response(content)
        if content:find("INTENT_RESPONSE") then
            self.intent = { TOOL = "patch", GOAL = "test" }
            return { stage = "generate", prompt = "[GENERATE PROMPT] Generate the patch payload" }
        elseif content:find("GENERATE_RESPONSE") then
            return { stage = "execute", tool = "patch", payload = "file.lua\nSEARCH/REPLACE block" }
        elseif content:find("REVIEW_RESPONSE_APPROVE") then
            self.state = "APPROVED"
            return { stage = "done", result = "[PATCH APPLIED] file.lua modified successfully", iterations = 1 }
        elseif content:find("REVIEW_RESPONSE_REVISE") then
            return { stage = "generate", prompt = "[GENERATE PROMPT] Revise based on feedback" }
        end
        return { stage = "error", message = "Unexpected response: " .. tostring(content):sub(1, 50) }
    end
    function M:feed_execution_result(output)
        local output_str = type(output) == "table" and (output.output or "") or tostring(output)
        self.last_result = output_str
        return { stage = "review", prompt = "[REVIEW PROMPT] Review the execution result" }
    end
    function M:save_state()
        self.save_state_calls = self.save_state_calls + 1
    end
    return M
end
local function make_mock_executor_error_flow()
    local M = {}
    M.intent = { TOOL = "patch", GOAL = "test goal" }
    M.save_state_calls = 0
    function M:start_task(task, project_context)
        return { stage = "intent", prompt = "[INTENT PROMPT] Plan: " .. task }
    end
    function M:feed_response(content)
        if content:find("INTENT_RESPONSE") then
            self.intent = { TOOL = "patch", GOAL = "test" }
            return { stage = "generate", prompt = "[GENERATE PROMPT] Generate payload" }
        elseif content:find("GENERATE_RESPONSE") then
            return { stage = "execute", tool = "patch", payload = "bad_payload" }
        end
        return { stage = "error", message = "parse failed" }
    end
    function M:feed_execution_result(output)
        self.iteration = 3
        self.max_iterations = 3
        return { stage = "error", message = "Failed after 3 iterations" }
    end
    function M:save_state()
        self.save_state_calls = self.save_state_calls + 1
    end
    return M
end
local function make_mock_executor_multi_iter_flow()
    local M = {}
    M.intent = { TOOL = "create_file", GOAL = "test goal" }
    M.save_state_calls = 0
    M.iteration = 1
    function M:start_task(task, project_context)
        return { stage = "intent", prompt = "[INTENT PROMPT] Plan: " .. task }
    end
    function M:feed_response(content)
        if content:find("INTENT_RESPONSE") then
            self.intent = { TOOL = "create_file", GOAL = "test" }
            return { stage = "generate", prompt = "[GENERATE PROMPT] v1" }
        elseif content:find("GENERATE_RESPONSE_V1") then
            return { stage = "execute", tool = "create_file", payload = "file.lua\ncontent_v1" }
        elseif content:find("REVIEW_RESPONSE_REVISE") then
            self.iteration = 2
            return { stage = "generate", prompt = "[GENERATE PROMPT] v2 (revised)" }
        elseif content:find("GENERATE_RESPONSE_V2") then
            return { stage = "execute", tool = "create_file", payload = "file.lua\ncontent_v2" }
        elseif content:find("REVIEW_RESPONSE_APPROVE") then
            return { stage = "done", result = "[FILE CREATED] file.lua with content_v2", iterations = 2 }
        end
        return { stage = "error", message = "Unexpected: " .. tostring(content):sub(1, 50) }
    end
    function M:feed_execution_result(output)
        local output_str = type(output) == "table" and (output.output or "") or tostring(output)
        self.last_result = output_str
        return { stage = "review", prompt = "[REVIEW PROMPT] Review result" }
    end
    function M:save_state()
        self.save_state_calls = self.save_state_calls + 1
    end
    return M
end
-- ============================================================
-- Tests
-- ============================================================
describe("Multi-Stage KV-Cache Fork-and-Rollback", function()
    local config
    before_each(function()
        config = {
            PROJECT_ROOT = "/tmp/test_kv_cache",
            AGENTS = { test_agent = {} },
            LIMITS = { MAX_CONTEXT = 128000, RESERVED_OUTPUT = 4096, SYSTEM_PROMPT_ESTIMATE = 2048, CHARS_PER_TOKEN = 3.5 },
            AGENT_DEFAULTS = { min_max_tokens = 1024 },
        }
    end)
    describe("Prefix Stability (KV-Cache Hit)", function()
        it("builds base_messages exactly ONCE via ctx:build_context", function()
            local initial_history = {
                { role = "user", content = "Hello" },
                { role = "assistant", content = "Hi there" },
                { role = "user", content = "Do the task" },
            }
            local ctx = make_mock_ctx(initial_history)
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Do the task", "TEST",
                false, nil, ctx, config, deps
            )
            assert.are.equal(1, ctx.build_context_call_count,
                "build_context must be called exactly once for KV-cache optimization")
        end)
        it("prefix is byte-identical across all LLM calls", function()
            local initial_history = {
                { role = "user", content = "First message" },
                { role = "assistant", content = "First response" },
                { role = "user", content = "Now do the task" },
            }
            local ctx = make_mock_ctx(initial_history)
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Now do the task", "TEST",
                false, nil, ctx, config, deps
            )
            assert.are.equal(3, mock_llm.call_count, "Expected 3 LLM calls")
            local base_prefix_len = 4  -- 1 system + 3 history
            -- Call 1 (intent) and Call 3 (review) use base_messages prefix
            -- Call 2 (generate) uses minimal generate_prefix (1 system msg)
            for i = 1, base_prefix_len do
                assert.are.equal(mock_llm.calls[1][i].role, mock_llm.calls[3][i].role,
                    string.format("Intent vs Review msg %d: role mismatch", i))
                assert.are.equal(mock_llm.calls[1][i].content, mock_llm.calls[3][i].content,
                    string.format("Intent vs Review msg %d: content mismatch (KV-cache miss!)", i))
            end
            -- Generate call now uses the same full base prefix as intent/review
            assert.are.equal(base_prefix_len, #mock_llm.calls[2] - 3, "Generate call should use full base prefix")
        end)
        it("tail grows incrementally with each stage", function()
            local initial_history = { { role = "user", content = "Task please" } }
            local ctx = make_mock_ctx(initial_history)
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Task please", "TEST",
                false, nil, ctx, config, deps
            )
            local base_len = 2  -- 1 system + 1 history
            assert.are.equal(base_len + 1, #mock_llm.calls[1], "Call 1 (intent): base + 1 tail")
            assert.are.equal(base_len + 3, #mock_llm.calls[2], "Call 2 (generate): base + 3 tail")
            assert.are.equal(base_len + 5, #mock_llm.calls[3], "Call 3 (review): base + 5 tail")
        end)
    end)
    describe("Checkpoint and Rollback", function()
        it("history is rolled back to checkpoint on success", function()
            local initial_history = {
                { role = "user", content = "Msg 1" },
                { role = "assistant", content = "Resp 1" },
                { role = "user", content = "Do task" },
            }
            local ctx = make_mock_ctx(initial_history)
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            local result = multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Do task", "TEST",
                false, nil, ctx, config, deps
            )
            assert.are.equal("AUTO_LOOP", result)
            local final_history = ctx.history.test_agent
            assert.are.equal(4, #final_history, "checkpoint(3) + 1 summary")
            assert.are.equal("Msg 1", final_history[1].content)
            assert.are.equal("Resp 1", final_history[2].content)
            assert.are.equal("Do task", final_history[3].content)
        end)
        it("history is rolled back to checkpoint on error", function()
            local initial_history = {
                { role = "user", content = "Msg 1" },
                { role = "assistant", content = "Resp 1" },
                { role = "user", content = "Do task" },
            }
            local ctx = make_mock_ctx(initial_history)
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_error_flow()
            local result = multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Do task", "TEST",
                false, nil, ctx, config, deps
            )
            assert.are.equal("ERROR", result)
            local final_history = ctx.history.test_agent
            assert.are.equal(4, #final_history, "checkpoint(3) + 1 error msg")
            assert.are.equal("Msg 1", final_history[1].content)
        end)
    end)
    describe("Summary Message Format", function()
        it("success summary contains tool name, iterations, and result", function()
            local ctx = make_mock_ctx({ { role = "user", content = "Patch the file" } })
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Patch the file", "TEST",
                false, nil, ctx, config, deps
            )
            local final_history = ctx.history.test_agent
            local summary = final_history[#final_history]
            assert.are.equal("system", summary.role)
            assert.truthy(summary.content:find("[MULTI-STAGE RESULT]"))
            assert.truthy(summary.content:find("patch"))
            assert.truthy(summary.content:find("Iterations:"))
            assert.truthy(summary.content:find("[PATCH APPLIED]"))
        end)
        it("error summary contains failure info", function()
            local ctx = make_mock_ctx({ { role = "user", content = "Do something" } })
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_error_flow()
            multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Do something", "TEST",
                false, nil, ctx, config, deps
            )
            local final_history = ctx.history.test_agent
            local summary = final_history[#final_history]
            assert.are.equal("system", summary.role)
            assert.truthy(summary.content:find("[MULTI-STAGE ERROR]"))
            assert.truthy(summary.content:find("Failed:"))
        end)
        it("long results are truncated to 500 chars", function()
            local ctx = make_mock_ctx({ { role = "user", content = "Big task" } })
            local long_executor = make_mock_executor_full_flow()
            local orig_feed = long_executor.feed_response
            function long_executor:feed_response(content)
                if content:find("REVIEW_RESPONSE_APPROVE") then
                    self.state = "APPROVED"
                    return { stage = "done", result = string.rep("X", 2000), iterations = 1 }
                end
                return orig_feed(self, content)
            end
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            multi_stage.run_multi_stage_loop(
                long_executor, "test_agent", {}, "Big task", "TEST",
                false, nil, ctx, config, deps
            )
            local final_history = ctx.history.test_agent
            local summary = final_history[#final_history]
            assert.is_true(#summary.content < 700, "Should be truncated, got: " .. #summary.content)
            assert.truthy(summary.content:find("%.%.%.%[truncated%]"))
        end)
    end)
    describe("Multi-Iteration Flow", function()
        it("handles REVISE then APPROVE cycle with stable prefix", function()
            local ctx = make_mock_ctx({ { role = "user", content = "Create a file" } })
            local mock_llm = make_mock_llm({
                "INTENT_RESPONSE", "GENERATE_RESPONSE_V1", "REVIEW_RESPONSE_REVISE",
                "GENERATE_RESPONSE_V2", "REVIEW_RESPONSE_APPROVE",
            })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_multi_iter_flow()
            local result = multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Create a file", "TEST",
                false, nil, ctx, config, deps
            )
            assert.are.equal("AUTO_LOOP", result)
            assert.are.equal(5, mock_llm.call_count)
            local base_len = 2
            -- Non-generate calls (1,3,5) use base prefix; generate calls (2,4) use minimal prefix
            local non_gen_calls = {1, 3, 5}
            for _, call_idx in ipairs(non_gen_calls) do
                for i = 1, base_len do
                    assert.are.equal(mock_llm.calls[1][i].content, mock_llm.calls[call_idx][i].content,
                        string.format("Prefix mismatch at call %d msg %d", call_idx, i))
                end
            end
            -- Generate calls now use the same full base prefix as other stages
            for i = 1, #mock_llm.calls[1] do
                assert.are.equal(mock_llm.calls[1][i].role, mock_llm.calls[2][i].role,
                    "Generate vs Intent msg %d: role mismatch", i)
                assert.are.equal(mock_llm.calls[1][i].content, mock_llm.calls[2][i].content,
                    "Generate vs Intent msg %d: content mismatch (KV-cache miss!)", i)
            end
            local final_history = ctx.history.test_agent
            assert.are.equal(2, #final_history)
            assert.truthy(final_history[2].content:find("[MULTI-STAGE RESULT]"))
            assert.truthy(final_history[2].content:find("Iterations: 2"))
        end)
    end)
    describe("skip_intent Path", function()
        it("works with pre-supplied intent (fewer LLM calls)", function()
            local ctx = make_mock_ctx({ { role = "user", content = "Direct task" } })
            local mock_llm = make_mock_llm({ "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            local intent_params = {
                tool_name = "patch", payload_hint = "modify line 5",
                success_criteria = "line 5 changed", file_path = "test.lua",
            }
            local result = multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Direct task", "TEST",
                true, intent_params, ctx, config, deps
            )
            assert.are.equal("AUTO_LOOP", result)
            assert.are.equal(2, mock_llm.call_count, "skip_intent: only generate + review")
        end)
    end)
    describe("Edge Cases", function()
        it("handles empty initial history", function()
            local ctx = make_mock_ctx({})
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            local result = multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Task", "TEST",
                false, nil, ctx, config, deps
            )
            assert.are.equal("AUTO_LOOP", result)
            local final_history = ctx.history.test_agent
            assert.are.equal(1, #final_history)
            assert.truthy(final_history[1].content:find("[MULTI-STAGE RESULT]"))
        end)
        it("does not mutate original history during processing", function()
            local initial_history = {
                { role = "user", content = "Original msg 1" },
                { role = "assistant", content = "Original resp 1" },
            }
            local ctx = make_mock_ctx(initial_history)
            local snapshot = {}
            for i, msg in ipairs(ctx.history.test_agent) do
                snapshot[i] = { role = msg.role, content = msg.content }
            end
            local mock_llm = make_mock_llm({ "INTENT_RESPONSE", "GENERATE_RESPONSE", "REVIEW_RESPONSE_APPROVE" })
            local deps = make_deps(mock_llm)
            local executor = make_mock_executor_full_flow()
            multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Task", "TEST",
                false, nil, ctx, config, deps
            )
            local final_history = ctx.history.test_agent
            assert.are.equal(snapshot[1].role, final_history[1].role)
            assert.are.equal(snapshot[1].content, final_history[1].content)
            assert.are.equal(snapshot[2].role, final_history[2].role)
            assert.are.equal(snapshot[2].content, final_history[2].content)
        end)
        it("network error triggers rollback with error message", function()
            local ctx = make_mock_ctx({ { role = "user", content = "Task" } })
            local failing_llm = {}
            failing_llm.call_count = 0
            function failing_llm.send_request(agent_cfg, messages, opts)
                failing_llm.call_count = failing_llm.call_count + 1
                return nil, "Connection refused"
            end
            local deps = make_deps(failing_llm)
            local executor = make_mock_executor_full_flow()
            local result = multi_stage.run_multi_stage_loop(
                executor, "test_agent", {}, "Task", "TEST",
                false, nil, ctx, config, deps
            )
            assert.are.equal("ERROR", result)
            local final_history = ctx.history.test_agent
            assert.are.equal(2, #final_history)
            assert.truthy(final_history[2].content:find("[MULTI-STAGE ERROR]"))
        end)
    end)
end)
