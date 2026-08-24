-- agent/__tests__/test_multi_stage_history_integrity.lua
-- Verifies that ctx.history[agent_name] is NEVER mutated during multi-stage execution.
-- Only the final rollback + summary message modifies it.
local multi_stage = require("agent.multi_stage")
-- Mock LLM with scripted responses
local function make_mock_llm(responses)
    local M = { calls = {}, call_count = 0 }
    local idx = 1
    function M.send_request(_, messages, _)
        M.call_count = M.call_count + 1
        table.insert(M.calls, { n_msgs = #messages })
        local r = responses[idx] or "DEFAULT"
        idx = idx + 1
        return { choices = { [1] = { message = { content = r } } } }, nil
    end
    return M
end
-- Mock ctx with HISTORY SPY: records every mutation to history
local function make_spied_ctx(initial_history)
    local ctx = {
        history = {},
        file_tree = "tree",
        config = {
            PROJECT_ROOT = "/tmp/test_integrity",
            AGENTS = { test_agent = {} },
            LIMITS = { MAX_CONTEXT = 128000, RESERVED_OUTPUT = 4096, SYSTEM_PROMPT_ESTIMATE = 2048, CHARS_PER_TOKEN = 3.5 },
        },
    }
    -- Populate initial history
    ctx.history.test_agent = {}
    for i, msg in ipairs(initial_history) do
        table.insert(ctx.history.test_agent, { role = msg.role, content = msg.content })
    end
    -- SPY: track all mutations
    ctx._spy = {
        mutations_during_loop = 0,  -- mutations that happened (should be 0 during loop)
        final_adds = {},            -- messages added after loop (should be exactly 1 summary)
        history_length_at_start = #ctx.history.test_agent,
    }
    ctx.build_context_call_count = 0
    function ctx:build_context(agent_name, _, _)
        self.build_context_call_count = self.build_context_call_count + 1
        local h = self.history[agent_name] or {}
        local msgs = { { role = "system", content = "[SYS]" } }
        for i, m in ipairs(h) do table.insert(msgs, { role = m.role, content = m.content }) end
        return { messages = msgs }
    end
    function ctx:add_message(agent_name, role, content)
        self.history[agent_name] = self.history[agent_name] or {}
        table.insert(self.history[agent_name], { role = role, content = content })
        -- Track: if history length changed beyond initial+1, it's a mutation during loop
        local expected_final_len = self._spy.history_length_at_start + 1
        if #self.history[agent_name] > expected_final_len then
            self._spy.mutations_during_loop = self._spy.mutations_during_loop + 1
        end
        table.insert(self._spy.final_adds, { role = role, content = content })
    end
    return ctx
end
local function make_deps(mock_llm)
    return {
        logger = { info = function() end, warn = function() end, error = function() end },
        utils = {
            trim = function(s) if not s then return "" end return s:gsub("^%s*(.-)%s*$", "%1") end,
            sanitize_for_json = function(s) return s or "" end,
            stream_token_printer = function() return {} end,
            flush_stream_buffer = function() end,
        },
        llm = mock_llm,
        registry = { execute = function(cmd) return { output = "[OK] " .. cmd, signal = "SUCCESS" } end },
        context_optimizer = { shrink_max_tokens = function() return 1024 end },
        optimizer = { generate_continuation_prompt = function() return nil end },
    }
end
local function make_executor()
    local M = { intent = { TOOL = "patch", GOAL = "g" }, save_state_calls = 0 }
    function M:start_task(task, _)
        return { stage = "intent", prompt = "[INTENT] " .. task }
    end
    function M:feed_response(content)
        if content:find("INTENT") then
            return { stage = "generate", prompt = "[GEN] make patch" }
        elseif content:find("GEN") then
            return { stage = "execute", tool = "patch", payload = "f.lua\nS/R block" }
        elseif content:find("REVIEW_OK") then
            return { stage = "done", result = "[PATCH OK] applied", iterations = 1 }
        end
        return { stage = "error", message = "unexpected" }
    end
    function M:feed_execution_result(output)
        return { stage = "review", prompt = "[REVIEW] check result" }
    end
    function M:save_state() self.save_state_calls = self.save_state_calls + 1 end
    return M
end
local config = {
    PROJECT_ROOT = "/tmp/test_integrity",
    AGENTS = { test_agent = {} },
    LIMITS = { MAX_CONTEXT = 128000, RESERVED_OUTPUT = 4096, SYSTEM_PROMPT_ESTIMATE = 2048, CHARS_PER_TOKEN = 3.5 },
    AGENT_DEFAULTS = { min_max_tokens = 1024 },
}
describe("History Integrity During Multi-Stage", function()
    it("history is NOT mutated during the loop (only tail grows in memory)", function()
        local initial = {
            { role = "user", content = "msg_1" },
            { role = "assistant", content = "resp_1" },
            { role = "user", content = "msg_2" },
            { role = "assistant", content = "resp_2" },
            { role = "user", content = "do the task" },
        }
        local ctx = make_spied_ctx(initial)
        local mock_llm = make_mock_llm({ "INTENT_RESP", "GEN_RESP", "REVIEW_OK" })
        local deps = make_deps(mock_llm)
        local executor = make_executor()
        -- Snapshot history BEFORE
        local before_len = #ctx.history.test_agent
        local before_snapshot = {}
        for i, m in ipairs(ctx.history.test_agent) do
            before_snapshot[i] = { role = m.role, content = m.content }
        end
        local result = multi_stage.run_multi_stage_loop(
            executor, "test_agent", {}, "do the task", "TEST",
            false, nil, ctx, config, deps
        )
        assert.are.equal("AUTO_LOOP", result)
        -- History length should be exactly initial + 1 (summary)
        local after_len = #ctx.history.test_agent
        assert.are.equal(before_len + 1, after_len,
            string.format("History grew from %d to %d (expected %d). Mutations during loop: %d",
                before_len, after_len, before_len + 1, ctx._spy.mutations_during_loop))
        -- All original messages must be byte-identical
        for i = 1, before_len do
            assert.are.equal(before_snapshot[i].role, ctx.history.test_agent[i].role,
                string.format("Msg %d role changed", i))
            assert.are.equal(before_snapshot[i].content, ctx.history.test_agent[i].content,
                string.format("Msg %d content changed: '%s' -> '%s'", i, before_snapshot[i].content, ctx.history.test_agent[i].content))
        end
        -- The only new message is the summary at position before_len+1
        local summary = ctx.history.test_agent[before_len + 1]
        assert.are.equal("system", summary.role)
        assert.truthy(summary.content:find("[MULTI-STAGE RESULT]"))
        -- No mutations detected during loop
        assert.are.equal(0, ctx._spy.mutations_during_loop,
            "History was mutated during the multi-stage loop!")
    end)
    it("rollback restores exact checkpoint even after multiple iterations", function()
        local initial = {
            { role = "user", content = "A" },
            { role = "assistant", content = "B" },
            { role = "user", content = "C" },
        }
        local ctx = make_spied_ctx(initial)
        -- Multi-iteration: intent -> gen -> exec -> review(REVISE) -> gen -> exec -> review(APPROVE)
        local mock_llm = make_mock_llm({
            "INTENT_RESP", "GEN_V1", "REVIEW_REVISE", "GEN_V2", "REVIEW_OK"
        })
        -- Custom executor for multi-iteration
        local executor = { intent = { TOOL = "patch", GOAL = "g" }, save_state_calls = 0, iter = 1 }
        function executor:start_task(task, _)
            return { stage = "intent", prompt = "[INTENT] " .. task }
        end
        function executor:feed_response(content)
            if content:find("INTENT") then
                return { stage = "generate", prompt = "[GEN] v1" }
            elseif content:find("GEN_V1") then
                return { stage = "execute", tool = "patch", payload = "p1" }
            elseif content:find("REVIEW_REVISE") then
                self.iter = 2
                return { stage = "generate", prompt = "[GEN] v2 revised" }
            elseif content:find("GEN_V2") then
                return { stage = "execute", tool = "patch", payload = "p2" }
            elseif content:find("REVIEW_OK") then
                return { stage = "done", result = "[OK] done in 2 iters", iterations = 2 }
            end
            return { stage = "error", message = "bad" }
        end
        function executor:feed_execution_result(_)
            return { stage = "review", prompt = "[REVIEW] check" }
        end
        function executor:save_state() self.save_state_calls = self.save_state_calls + 1 end
        local deps = make_deps(mock_llm)
        local before_len = #ctx.history.test_agent
        local snapshot = {}
        for i, m in ipairs(ctx.history.test_agent) do
            snapshot[i] = { role = m.role, content = m.content }
        end
        local result = multi_stage.run_multi_stage_loop(
            executor, "test_agent", {}, "C", "TEST",
            false, nil, ctx, config, deps
        )
        assert.are.equal("AUTO_LOOP", result)
        assert.are.equal(5, mock_llm.call_count, "Expected 5 LLM calls")
        -- Final history: original 3 + 1 summary = 4
        assert.are.equal(before_len + 1, #ctx.history.test_agent)
        -- Original messages intact
        for i = 1, before_len do
            assert.are.equal(snapshot[i].role, ctx.history.test_agent[i].role)
            assert.are.equal(snapshot[i].content, ctx.history.test_agent[i].content)
        end
        -- Summary reflects multi-iteration
        local summary = ctx.history.test_agent[before_len + 1]
        assert.truthy(summary.content:find("Iterations: 2"))
    end)
    it("error path also rolls back cleanly", function()
        local initial = {
            { role = "user", content = "X" },
            { role = "assistant", content = "Y" },
        }
        local ctx = make_spied_ctx(initial)
        -- Executor that fails immediately
        local executor = { intent = { TOOL = "patch", GOAL = "g" }, save_state_calls = 0 }
        function executor:start_task(task, _)
            return { stage = "intent", prompt = "[INTENT] " .. task }
        end
        function executor:feed_response(content)
            if content:find("INTENT") then
                return { stage = "generate", prompt = "[GEN]" }
            elseif content:find("GEN") then
                return { stage = "execute", tool = "patch", payload = "bad" }
            end
            return { stage = "error", message = "parse fail" }
        end
        function executor:feed_execution_result(_)
            return { stage = "error", message = "Failed after max iterations" }
        end
        function executor:save_state() self.save_state_calls = self.save_state_calls + 1 end
        local mock_llm = make_mock_llm({ "INTENT_RESP", "GEN_RESP" })
        local deps = make_deps(mock_llm)
        local before_len = #ctx.history.test_agent
        local snapshot = {}
        for i, m in ipairs(ctx.history.test_agent) do snapshot[i] = { role = m.role, content = m.content } end
        local result = multi_stage.run_multi_stage_loop(
            executor, "test_agent", {}, "X", "TEST",
            false, nil, ctx, config, deps
        )
        assert.are.equal("ERROR", result)
        assert.are.equal(before_len + 1, #ctx.history.test_agent)
        for i = 1, before_len do
            assert.are.equal(snapshot[i].content, ctx.history.test_agent[i].content)
        end
        local summary = ctx.history.test_agent[before_len + 1]
        assert.truthy(summary.content:find("[MULTI-STAGE ERROR]"))
    end)
end)
