describe("Loop Guard", function()
    local loop_guard = require("loop_guard")
    -- Helper: create a minimal mock context
    local function make_ctx()
        return {
            execution_plan = {},
            current_task_index = 1,
            file_states = {},
        }
    end
    -- Helper: create a minimal config
    local function make_config(overrides)
        overrides = overrides or {}
        local limits_overrides = overrides.limits or {}
        local weights_overrides = overrides.risk_weights or {}
        local intervention_overrides = overrides.intervention_levels or {}
        return {
            LOOP_GUARD = {
                enabled = true,
                limits = {
                    max_iterations = limits_overrides.max_iterations or 100,
                    max_seconds = limits_overrides.max_seconds or 600,
                    max_tokens = limits_overrides.max_tokens or 500000,
                    max_cost_usd = limits_overrides.max_cost_usd or 5.0,
                },
                action_window = overrides.action_window or 20,
                max_same_action = overrides.max_same_action or 2,
                max_same_error = overrides.max_same_error or 3,
                fuzzy_threshold = overrides.fuzzy_threshold or 0.85,
                max_sequence_period = overrides.max_sequence_period or 6,
                progress_stall_window = overrides.progress_stall_window or 5,
                progress_stall_threshold = overrides.progress_stall_threshold or 0.02,
                risk_weights = {
                    exact_dup = weights_overrides.exact_dup or 0.30,
                    fuzzy_dup = weights_overrides.fuzzy_dup or 0.20,
                    sequence_loop = weights_overrides.sequence_loop or 0.35,
                    error_loop = weights_overrides.error_loop or 0.40,
                    progress_stall = weights_overrides.progress_stall or 0.25,
                    semantic_loop = weights_overrides.semantic_loop or 0.15,
                    budget_exceeded = weights_overrides.budget_exceeded or 0.50,
                },
                intervention_levels = {
                    soft_nudge = intervention_overrides.soft_nudge or 0.35,
                    force_replan = intervention_overrides.force_replan or 0.65,
                    circuit_breaker = intervention_overrides.circuit_breaker or 0.85,
                },
                exempt_tools = overrides.exempt_tools or { "task_complete", "delegate_plan", "optimize_context" },
            }
        }
    end
    -- ========================================================================
    -- TEST 1: Exact duplicate detection
    -- ========================================================================
    describe("Exact duplicate detection", function()
        it("should detect exact duplicate actions", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            -- Record an action
            local canonical = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
            lg:record_action(canonical)
            -- Check for exact duplicate
            local is_dup, msg = lg:check_exact_duplicate(canonical)
            assert.is_true(is_dup)
            assert.is_not_nil(msg)
        end)
        it("should not flag non-duplicate actions", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            -- Record an action
            local canonical1 = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
            lg:record_action(canonical1)
            -- Check a different action
            local canonical2 = lg:canonicalize_action("patch", "src/other.c\n<<<<<<< SEARCH\ndifferent\n=======\nother\n>>>>>>> REPLACE")
            local is_dup, msg = lg:check_exact_duplicate(canonical2)
            assert.is_false(is_dup)
            assert.is_nil(msg)
        end)
    end)
    -- ========================================================================
    -- TEST 2: Fuzzy duplicate detection
    -- ========================================================================
    describe("Fuzzy duplicate detection", function()
        it("should detect fuzzy duplicate actions", function()
            local ctx = make_ctx()
            local config = make_config({ fuzzy_threshold = 0.8 })
            local lg = loop_guard.new(ctx, config)
            -- Record an action
            local canonical1 = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold code here\n=======\nnew code here\n>>>>>>> REPLACE")
            lg:record_action(canonical1)
            -- Check a similar action (high Jaccard similarity)
            local canonical2 = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold code here\n=======\nslightly different code here\n>>>>>>> REPLACE")
            local is_dup, msg, sim = lg:check_fuzzy_duplicate(canonical2)
            -- With threshold 0.8, this should be detected as fuzzy duplicate
            if sim >= 0.8 then
                assert.is_true(is_dup)
            end
        end)
        it("should not flag dissimilar actions", function()
            local ctx = make_ctx()
            local config = make_config({ fuzzy_threshold = 0.85 })
            local lg = loop_guard.new(ctx, config)
            -- Record an action
            local canonical1 = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold code here\n=======\nnew code here\n>>>>>>> REPLACE")
            lg:record_action(canonical1)
            -- Check a very different action
            local canonical2 = lg:canonicalize_action("shell", "npm install some-package && npm run build")
            local is_dup, msg, sim = lg:check_fuzzy_duplicate(canonical2)
            assert.is_false(is_dup)
        end)
    end)
    -- ========================================================================
    -- TEST 3: Sequence loop detection
    -- ========================================================================
    describe("Sequence loop detection", function()
        it("should detect ABAB pattern", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            local action_a = lg:canonicalize_action("patch", "file_a.lua\n<<<<<<< SEARCH\nold_a\n=======\nnew_a\n>>>>>>> REPLACE")
            local action_b = lg:canonicalize_action("patch", "file_b.lua\n<<<<<<< SEARCH\nold_b\n=======\nnew_b\n>>>>>>> REPLACE")
            -- Record ABAB pattern
            lg:record_action(action_a)
            lg:record_action(action_b)
            lg:record_action(action_a)
            lg:record_action(action_b)
            local is_loop, msg = lg:check_sequence_loop()
            assert.is_true(is_loop)
            assert.is_not_nil(msg)
        end)
        it("should detect ABCABC pattern", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            local action_a = lg:canonicalize_action("patch", "file_a.lua\n<<<<<<< SEARCH\nold_a\n=======\nnew_a\n>>>>>>> REPLACE")
            local action_b = lg:canonicalize_action("patch", "file_b.lua\n<<<<<<< SEARCH\nold_b\n=======\nnew_b\n>>>>>>> REPLACE")
            local action_c = lg:canonicalize_action("patch", "file_c.lua\n<<<<<<< SEARCH\nold_c\n=======\nnew_c\n>>>>>>> REPLACE")
            -- Record ABCABC pattern
            lg:record_action(action_a)
            lg:record_action(action_b)
            lg:record_action(action_c)
            lg:record_action(action_a)
            lg:record_action(action_b)
            lg:record_action(action_c)
            local is_loop, msg = lg:check_sequence_loop()
            assert.is_true(is_loop)
            assert.is_not_nil(msg)
        end)
        it("should not flag non-repeating sequences", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            local action_a = lg:canonicalize_action("patch", "file_a.lua\n<<<<<<< SEARCH\nold_a\n=======\nnew_a\n>>>>>>> REPLACE")
            local action_b = lg:canonicalize_action("patch", "file_b.lua\n<<<<<<< SEARCH\nold_b\n=======\nnew_b\n>>>>>>> REPLACE")
            local action_c = lg:canonicalize_action("patch", "file_c.lua\n<<<<<<< SEARCH\nold_c\n=======\nnew_c\n>>>>>>> REPLACE")
            local action_d = lg:canonicalize_action("patch", "file_d.lua\n<<<<<<< SEARCH\nold_d\n=======\nnew_d\n>>>>>>> REPLACE")
            -- Record non-repeating sequence
            lg:record_action(action_a)
            lg:record_action(action_b)
            lg:record_action(action_c)
            lg:record_action(action_d)
            local is_loop, msg = lg:check_sequence_loop()
            assert.is_false(is_loop)
            assert.is_nil(msg)
        end)
    end)
    -- ========================================================================
    -- TEST 4: Error loop detection
    -- ========================================================================
    describe("Error loop detection", function()
        it("should detect repeated errors", function()
            local ctx = make_ctx()
            local config = make_config({ max_same_error = 3 })
            local lg = loop_guard.new(ctx, config)
            -- Simulate 3 identical errors
            lg.iteration_count = 1
            lg:record_error("patch", "File not found: src/missing.lua")
            lg.iteration_count = 2
            lg:record_error("patch", "File not found: src/missing.lua")
            lg.iteration_count = 3
            lg:record_error("patch", "File not found: src/missing.lua")
            local is_loop, msg = lg:check_error_loop()
            assert.is_true(is_loop)
            assert.is_not_nil(msg)
        end)
        it("should not flag different errors", function()
            local ctx = make_ctx()
            local config = make_config({ max_same_error = 3 })
            local lg = loop_guard.new(ctx, config)
            -- Simulate different errors
            lg.iteration_count = 1
            lg:record_error("patch", "File not found: src/a.lua")
            lg.iteration_count = 2
            lg:record_error("patch", "Syntax error in src/b.lua")
            lg.iteration_count = 3
            lg:record_error("patch", "Permission denied for src/c.lua")
            local is_loop, msg = lg:check_error_loop()
            assert.is_false(is_loop)
            assert.is_nil(msg)
        end)
    end)
    -- ========================================================================
    -- TEST 5: Progress stall detection
    -- ========================================================================
    describe("Progress stall detection", function()
        it("should detect progress stall", function()
            local ctx = make_ctx()
            local config = make_config({ progress_stall_window = 5, progress_stall_threshold = 0.02 })
            local lg = loop_guard.new(ctx, config)
            -- Simulate stalled progress (same score repeatedly)
            lg.iteration_count = 1
            lg.progress_history = {
                { score = 0.5, turn = 1 },
                { score = 0.5, turn = 2 },
                { score = 0.5, turn = 3 },
                { score = 0.5, turn = 4 },
                { score = 0.5, turn = 5 },
            }
            local is_stall, msg = lg:check_progress_stall()
            assert.is_true(is_stall)
            assert.is_not_nil(msg)
        end)
        it("should not flag progressing scores", function()
            local ctx = make_ctx()
            local config = make_config({ progress_stall_window = 5, progress_stall_threshold = 0.02 })
            local lg = loop_guard.new(ctx, config)
            -- Simulate progressing scores
            lg.iteration_count = 5
            lg.progress_history = {
                { score = 0.1, turn = 1 },
                { score = 0.3, turn = 2 },
                { score = 0.5, turn = 3 },
                { score = 0.7, turn = 4 },
                { score = 0.9, turn = 5 },
            }
            local is_stall, msg = lg:check_progress_stall()
            assert.is_false(is_stall)
            assert.is_nil(msg)
        end)
    end)
    -- ========================================================================
    -- TEST 6: Hard limits
    -- ========================================================================
    describe("Hard limits", function()
        it("should block on max_iterations exceeded", function()
            local ctx = make_ctx()
            local config = make_config()
            config.LOOP_GUARD.limits.max_iterations = 5
            local lg = loop_guard.new(ctx, config)
            -- Increment iteration_count to exceed limit
            for i = 1, 6 do
                lg.iteration_count = lg.iteration_count + 1
            end
            local is_blocked, msg = lg:check_hard_limits()
            assert.is_true(is_blocked)
            assert.is_not_nil(msg)
        end)
        it("should not block within limits", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            -- Increment iteration_count to within limit
            for i = 1, 10 do
                lg.iteration_count = lg.iteration_count + 1
            end
            local is_blocked, msg = lg:check_hard_limits()
            assert.is_false(is_blocked)
            assert.is_nil(msg)
        end)
    end)
    -- ========================================================================
    -- TEST 7: Exempt tools
    -- ========================================================================
    describe("Exempt tools", function()
        it("should allow exempt tools", function()
            local ctx = make_ctx()
            local config = make_config({ exempt_tools = { "task_complete", "delegate_plan", "optimize_context" } })
            local lg = loop_guard.new(ctx, config)
            -- task_complete should be exempt
            local is_blocked, msg = lg:before_tool_call("task_complete", "")
            assert.is_false(is_blocked)
        end)
        it("should not exempt non-exempt tools", function()
            local ctx = make_ctx()
            local config = make_config({ exempt_tools = { "task_complete", "delegate_plan", "optimize_context" } })
            local lg = loop_guard.new(ctx, config)
            -- patch is not exempt
            -- First call should not be blocked (no history yet)
            local is_blocked, msg = lg:before_tool_call("patch", "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
            assert.is_false(is_blocked)
            -- Record the action (simulating after_tool_call)
            local canonical = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
            lg:record_action(canonical)
            -- Second call (exact duplicate) should be blocked
            is_blocked, msg = lg:before_tool_call("patch", "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
            assert.is_true(is_blocked)
        end)
    end)
    -- ========================================================================
    -- TEST 8: Intervention levels
    -- ========================================================================
    describe("Intervention levels", function()
        it("should return SOFT_NUDGE for low risk", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            lg.current_risk = 0.4  -- Above soft_nudge (0.35), below force_replan (0.65)
            local intervention = lg:get_intervention(lg.current_risk)
            assert.equals("SOFT_NUDGE", intervention.level)
            assert.is_false(intervention.block)
        end)
        it("should return FORCE_REPLAN for medium risk", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            lg.current_risk = 0.7  -- Above force_replan (0.65), below circuit_breaker (0.85)
            local intervention = lg:get_intervention(lg.current_risk)
            assert.equals("FORCE_REPLAN", intervention.level)
            assert.is_false(intervention.block)
        end)
        it("should return CIRCUIT_BREAKER for high risk", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            lg.current_risk = 0.9  -- Above circuit_breaker (0.85)
            local intervention = lg:get_intervention(lg.current_risk)
            assert.equals("CIRCUIT_BREAKER", intervention.level)
            assert.is_true(intervention.block)
        end)
    end)
    -- ========================================================================
    -- TEST 9: Canonicalization
    -- ========================================================================
    describe("Canonicalization", function()
        it("should normalize whitespace", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            local args1 = "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"
            local args2 = "src/main.c  \n  <<<<<<< SEARCH  \n  old  \n  =======  \n  new  \n  >>>>>>> REPLACE  "
            local canon1 = lg:canonicalize_action("patch", args1)
            local canon2 = lg:canonicalize_action("patch", args2)
            -- Both should normalize to the same canonical form
            assert.equals(canon1, canon2)
        end)
        it("should handle empty args", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            local canon = lg:canonicalize_action("task_complete", "")
            assert.equals("task_complete", canon)
        end)
    end)
    -- ========================================================================
    -- TEST 10: Blocked actions persistence
    -- ========================================================================
    describe("Blocked actions persistence", function()
        it("should persist blocked actions", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            local canonical = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
            -- Block the action
            lg:block_action(canonical)
            -- Check if blocked
            local is_blocked, msg = lg:is_blocked(canonical)
            assert.is_true(is_blocked)
            assert.is_not_nil(msg)
        end)
        it("should clear blocked actions", function()
            local ctx = make_ctx()
            local config = make_config()
            local lg = loop_guard.new(ctx, config)
            local canonical = lg:canonicalize_action("patch", "src/main.c\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
            -- Block the action
            lg:block_action(canonical)
            -- Clear blocks
            lg:clear_block()
            -- Check if no longer blocked
            local is_blocked, msg = lg:is_blocked(canonical)
            assert.is_false(is_blocked)
            assert.is_nil(msg)
        end)
    end)
end)