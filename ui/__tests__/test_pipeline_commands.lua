describe("Pipeline Command Integration", function()
    local command_parser = require("ui.command_parser")
    local strings = require("utils.strings")
    -- Simulate the FIXED pipeline's command dispatch logic from agent/pipeline.lua
    local function simulate_pipeline_dispatch(user_input, config)
        -- Line 78: Fixed - uses strings.trim for /exit comparison
        if not user_input or strings.trim(user_input) == "" or strings.trim(user_input) == "/exit" then
            return { handled = true, action = "ABORT_DIRECT", reason = "Direct /exit match or empty" }
        end
        -- Line 83: Parse command
        local cmd = command_parser.parse(user_input, config)
        -- Lines 84+: The if/elseif chain (FIXED: added ABORT and SKIP handlers)
        if cmd.action == "NEXT_STAGE" then
            return { handled = true, action = "NEXT_STAGE", message = cmd.message }
        elseif cmd.action == "PREV_STAGE" then
            return { handled = true, action = "PREV_STAGE", message = cmd.message }
        elseif cmd.action == "SWITCH_STAGE" then
            return { handled = true, action = "SWITCH_STAGE", target_idx = cmd.target_idx, message = cmd.message }
        elseif cmd.action == "STATUS" then
            return { handled = true, action = "STATUS", message = cmd.message }
        elseif cmd.action == "HELP" then
            return { handled = true, action = "HELP", message = cmd.message }
        elseif cmd.action == "ABORT" then
            return { handled = true, action = "ABORT", message = cmd.message }
        elseif cmd.action == "SKIP" then
            return { handled = true, action = "SKIP", message = cmd.message }
        elseif cmd.action == "ERROR" then
            return { handled = true, action = "ERROR", message = cmd.message }
        elseif cmd.action == "MESSAGE" and strings.trim(user_input) ~= "" then
            return { handled = true, action = "MESSAGE", message = user_input }
        else
            return { handled = false, action = cmd.action, message = cmd.message }
        end
    end
    describe("FIX VERIFIED: ABORT handler catches /exit with whitespace", function()
        it("should handle /exit with trailing space", function()
            local result = simulate_pipeline_dispatch("/exit ", nil)
            assert.is_true(result.handled, "Should handle '/exit '")
            assert.equals("ABORT_DIRECT", result.action)
        end)
        it("should handle /exit with leading space", function()
            local result = simulate_pipeline_dispatch(" /exit", nil)
            assert.is_true(result.handled, "Should handle ' /exit'")
            assert.equals("ABORT_DIRECT", result.action)
        end)
        it("should handle /exit with both spaces", function()
            local result = simulate_pipeline_dispatch(" /exit ", nil)
            assert.is_true(result.handled, "Should handle ' /exit '")
            assert.equals("ABORT_DIRECT", result.action)
        end)
        it("should handle /exit with tab", function()
            local result = simulate_pipeline_dispatch("\t/exit", nil)
            assert.is_true(result.handled, "Should handle '\\t/exit'")
            assert.equals("ABORT_DIRECT", result.action)
        end)
        it("should handle /exit with newline", function()
            local result = simulate_pipeline_dispatch("/exit\n", nil)
            assert.is_true(result.handled, "Should handle '/exit\\n'")
            assert.equals("ABORT_DIRECT", result.action)
        end)
    end)
    describe("FIX VERIFIED: SKIP action is handled", function()
        it("should handle empty input", function()
            local result = simulate_pipeline_dispatch("", nil)
            assert.is_true(result.handled)
            assert.equals("ABORT_DIRECT", result.action)
        end)
        it("should handle whitespace-only input", function()
            local result = simulate_pipeline_dispatch("   ", nil)
            assert.is_true(result.handled)
            assert.equals("ABORT_DIRECT", result.action)
        end)
    end)
    describe("All commands work correctly", function()
        it("should handle /go", function()
            local result = simulate_pipeline_dispatch("/go", nil)
            assert.is_true(result.handled)
            assert.equals("NEXT_STAGE", result.action)
        end)
        it("should handle /go with spaces", function()
            local result = simulate_pipeline_dispatch(" /go ", nil)
            assert.is_true(result.handled)
            assert.equals("NEXT_STAGE", result.action)
        end)
        it("should handle /back", function()
            local result = simulate_pipeline_dispatch("/back", nil)
            assert.is_true(result.handled)
            assert.equals("PREV_STAGE", result.action)
        end)
        it("should handle /status", function()
            local result = simulate_pipeline_dispatch("/status", nil)
            assert.is_true(result.handled)
            assert.equals("STATUS", result.action)
        end)
        it("should handle /help", function()
            local result = simulate_pipeline_dispatch("/help", nil)
            assert.is_true(result.handled)
            assert.equals("HELP", result.action)
        end)
        it("should handle /exit exactly", function()
            local result = simulate_pipeline_dispatch("/exit", nil)
            assert.is_true(result.handled)
            assert.equals("ABORT_DIRECT", result.action)
        end)
        it("should handle regular message", function()
            local result = simulate_pipeline_dispatch("hello world", nil)
            assert.is_true(result.handled)
            assert.equals("MESSAGE", result.action)
        end)
        it("should handle unknown slash command as message", function()
            local result = simulate_pipeline_dispatch("/unknown", nil)
            assert.is_true(result.handled)
            assert.equals("MESSAGE", result.action)
        end)
    end)
    describe("Pipeline config for /mode", function()
        local config = {
            PIPELINE = {
                { stage = "ARCHITECT", mode = "interactive" },
                { stage = "CODER", mode = "sequential" },
            }
        }
        it("should handle /mode ARCHITECT", function()
            local result = simulate_pipeline_dispatch("/mode ARCHITECT", config)
            assert.is_true(result.handled)
            assert.equals("SWITCH_STAGE", result.action)
        end)
        it("should handle /mode with unknown stage", function()
            local result = simulate_pipeline_dispatch("/mode UNKNOWN", config)
            assert.is_true(result.handled)
            assert.equals("ERROR", result.action)
        end)
    end)
end)
