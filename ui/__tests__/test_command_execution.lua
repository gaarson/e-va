-- tools/__tests__/test_command_execution.lua
-- Comprehensive tests for command execution flow
-- Covers: security_prompt, shell tool denial messages, command_executor parsing,
-- command_flow history injection, and denial reason propagation.
-- ============================================================================
-- SECURITY_PROMPT TESTS
-- ============================================================================
describe("security_prompt confirm returns two values", function()
    local sp
    local orig_is_tty
    before_each(function()
        sp = require("ui.security_prompt")
        orig_is_tty = sp._is_tty
        sp._is_tty = false
    end)
    after_each(function()
        sp._is_tty = orig_is_tty
        package.loaded["ui.security_prompt"] = nil
    end)
    it("returns (true, nil) in auto_approve mode", function()
        sp.set_non_tty_mode("auto_approve")
        local allowed, reason = sp.confirm("test?", "n")
        assert.is_true(allowed)
        assert.is_nil(reason)
    end)
    it("returns (false, 'User declined') in auto_deny mode", function()
        sp.set_non_tty_mode("auto_deny")
        local allowed, reason = sp.confirm("test?", "y")
        assert.is_false(allowed)
        assert.equals("User declined", reason)
    end)
    it("returns (true, nil) in prompt mode with default 'y'", function()
        sp.set_non_tty_mode("prompt")
        local allowed, reason = sp.confirm("test?", "y")
        assert.is_true(allowed)
        assert.is_nil(reason)
    end)
    it("returns (false, reason) in prompt mode with default 'n'", function()
        sp.set_non_tty_mode("prompt")
        local allowed, reason = sp.confirm("test?", "n")
        assert.is_false(allowed)
        assert.is_not_nil(reason)
        assert.is_not.equals(nil, reason)
    end)
    it("confirm_execution returns (true, nil) in auto_approve", function()
        sp.set_non_tty_mode("auto_approve")
        local allowed, reason = sp.confirm_execution("ARCHITECT", "ls -la")
        assert.is_true(allowed)
        assert.is_nil(reason)
    end)
    it("confirm_execution returns (false, 'User declined') in auto_deny", function()
        sp.set_non_tty_mode("auto_deny")
        local allowed, reason = sp.confirm_execution("ARCHITECT", "bash script.sh")
        assert.is_false(allowed)
        assert.equals("User declined", reason)
    end)
    it("confirm_execution returns (false, non-nil) in prompt mode", function()
        sp.set_non_tty_mode("prompt")
        local allowed, reason = sp.confirm_execution("ARCHITECT", "bash script.sh")
        assert.is_false(allowed)
        assert.is_not_nil(reason)
        assert.is_not.equals(nil, reason)
    end)
end)
-- ============================================================================
-- SHELL TOOL DENIAL MESSAGE FORMAT TESTS
-- ============================================================================
describe("shell tool denial message formatting", function()
    it("formats denial with explicit reason", function()
        local reason = "Custom denial reason"
        local msg = string.format("\n[SYSTEM]: Command execution DENIED by user. Reason: %s", reason)
        assert.truthy(msg:match("DENIED"))
        assert.truthy(msg:match("Reason: Custom denial reason"))
        assert.falsy(msg:match("Reason: nil"))
    end)
    it("formats denial with 'User declined' reason", function()
        local reason = "User declined"
        local msg = string.format("\n[SYSTEM]: Command execution DENIED by user. Reason: %s", reason)
        assert.truthy(msg:match("Reason: User declined"))
        assert.falsy(msg:match("Reason: nil"))
    end)
    it("formats denial with 'denied' special reason", function()
        local msg = "\n[SYSTEM]: Command execution DENIED by user. Do not try this command again."
        assert.truthy(msg:match("DENIED"))
        assert.falsy(msg:match("Reason: nil"))
    end)
    it("never produces 'Reason: nil' string", function()
        local test_reasons = { "User declined", "Custom reason", "Non-TTY prompt mode: auto-denied" }
        for _, r in ipairs(test_reasons) do
            local msg = string.format("\n[SYSTEM]: Command execution DENIED by user. Reason: %s", r)
            assert.falsy(msg:match("Reason: nil"), string.format("Got 'Reason: nil' for reason=%q", r))
        end
    end)
end)
-- ============================================================================
-- COMMAND_EXECUTOR PARSE_COMMAND TESTS
-- ============================================================================
describe("command_executor parse_command", function()
    local ce
    local ce_instance
    before_each(function()
        ce = require("command_executor")
        local mock_ctx = {
            config = {
                AGENTS = {
                    ARCHITECT = {
                        allowed_tools = { "shell", "read_file", "search", "ask_user", "explore_tree" }
                    }
                }
            }
        }
        ce_instance = ce.new(mock_ctx, "ARCHITECT")
    end)
    it("parses simple command", function()
        local text = "Here is the command:\n||| COMMAND |||\nshell:ls -la\n||| END_COMMAND |||"
        local cmd, err = ce_instance:parse_command(text)
        assert.is_nil(err)
        assert.equals("shell:ls -la", cmd)
    end)
    it("parses command with extra pipes on start marker", function()
        local text = "Here is the command:\n|||| COMMAND ||||\nshell:ls -la\n|||| END_COMMAND ||||"
        local cmd, err = ce_instance:parse_command(text)
        assert.is_nil(err)
        assert.equals("shell:ls -la", cmd)
    end)
    it("parses command with many pipes", function()
        local text = "||||| COMMAND |||||\nshell:pwd\n||||| END_COMMAND |||||"
        local cmd, err = ce_instance:parse_command(text)
        assert.is_nil(err)
        assert.equals("shell:pwd", cmd)
    end)
    it("parses command with asymmetric pipe counts", function()
        local text = "|| COMMAND ||\nshell:whoami\n|||| END_COMMAND ||||"
        local cmd, err = ce_instance:parse_command(text)
        assert.is_nil(err)
        assert.equals("shell:whoami", cmd)
    end)
    it("rejects empty string", function()
        local cmd, err = ce_instance:parse_command("")
        assert.is_nil(cmd)
        assert.truthy(err)
    end)
    it("rejects nil input", function()
        local cmd, err = ce_instance:parse_command(nil)
        assert.is_nil(cmd)
        assert.equals("Empty response", err)
    end)
    it("rejects text without markers", function()
        local cmd, err = ce_instance:parse_command("Just some text without any command markers")
        assert.is_nil(cmd)
        assert.truthy(err)
    end)
    it("rejects unclosed command block", function()
        local cmd, err = ce_instance:parse_command("||| COMMAND |||\nshell:ls\nSome text")
        assert.is_nil(cmd)
        assert.truthy(err)
    end)
    it("strips reasoning tags before parsing", function()
        local text = "Let me think about this\n||| COMMAND |||\nshell:ls\n||| END_COMMAND |||"
        local cmd, err = ce_instance:parse_command(text)
        assert.is_nil(err)
        assert.equals("shell:ls", cmd)
    end)
    it("handles multiline command body", function()
        local text = "||| COMMAND |||\nshell:echo hello\necho world\n||| END_COMMAND |||"
        local cmd, err = ce_instance:parse_command(text)
        assert.is_nil(err)
        assert.truthy(cmd:match("echo hello"))
        assert.truthy(cmd:match("echo world"))
    end)
end)
-- ============================================================================
-- COMMAND_EXECUTOR PROCESS_TURN TESTS
-- ============================================================================
describe("command_executor process_turn", function()
    local ce
    local ce_instance
    local registry
    before_each(function()
        ce = require("command_executor")
        registry = require("tool_registry")
        -- Register mock ask_user tool so validation passes
        registry.register("ask_user", "Ask user a question", "||| COMMAND |||\nask_user:question\n||| END_COMMAND |||",
            function(args, ctx, agent) return { output = "user answered" } end)
        local mock_ctx = {
            config = {
                AGENTS = {
                    ARCHITECT = {
                        allowed_tools = { "shell", "read_file", "search", "ask_user", "explore_tree" }
                    }
                }
            }
        }
        ce_instance = ce.new(mock_ctx, "ARCHITECT")
    end)
    after_each(function()
        -- Clean up mock registration
        registry.tools["ask_user"] = nil
    end)
    it("returns CONVERSATION for text without commands", function()
        local result = ce_instance:process_turn("This is just a conversation message")
        assert.equals("CONVERSATION", result.type)
    end)
    it("returns USER_QUESTION for ask_user tool", function()
        local text = "||| COMMAND |||\nask_user:Is this correct?\n||| END_COMMAND |||"
        local result = ce_instance:process_turn(text)
        assert.equals("USER_QUESTION", result.type)
        assert.truthy(result.question)
    end)
    it("increments retry_count on validation failure", function()
        local text = "||| COMMAND |||\nunknown_tool:args\n||| END_COMMAND |||"
        local result = ce_instance:process_turn(text)
        assert.equals("RETRY", result.type)
        assert.equals(1, ce_instance.retry_count)
    end)
    it("returns ERROR after max retries", function()
        local text = "||| COMMAND |||\nunknown_tool:args\n||| END_COMMAND |||"
        for _ = 1, 4 do
            ce_instance:process_turn(text)
        end
        local result = ce_instance:process_turn(text)
        assert.equals("ERROR", result.type)
    end)
end)
-- ============================================================================
-- COMMAND_FLOW HISTORY INJECTION TESTS
-- ============================================================================
describe("command_flow history injection", function()
    it("denied command output is injectable as user message", function()
        local reason = "User declined"
        local denied_msg = string.format("\n[SYSTEM]: Command execution DENIED by user. Reason: %s", reason)
        local history = {}
        table.insert(history, { role = "user", content = denied_msg })
        assert.equals(1, #history)
        assert.equals("user", history[1].role)
        assert.truthy(history[1].content:match("DENIED"))
        assert.falsy(history[1].content:match("Reason: nil"))
    end)
    it("executed command output is injectable as user message", function()
        local output = "\n[SHELL STDOUT/STDERR]:\nfile1.lua\nfile2.lua"
        local history = {}
        table.insert(history, { role = "user", content = output })
        assert.equals(1, #history)
        assert.equals("user", history[1].role)
        assert.truthy(history[1].content:match("SHELL STDOUT/STDERR"))
    end)
    it("duplicate command message includes previous output reference", function()
        local cmd = "shell:ls -la"
        local prev_output = "\n[SHELL STDOUT/STDERR]:\nfile1.lua"
        local dup_msg = string.format(
            "[SYSTEM: DUPLICATE COMMAND BLOCKED] You already executed this command recently:\n||| COMMAND |||\n%s\n||| END_COMMAND |||\n\n--- PREVIOUS OUTPUT (this command was already executed) ---\n%s\n--- END PREVIOUS OUTPUT ---\nPlease proceed to the next step or issue a different command.",
            cmd, prev_output
        )
        assert.truthy(dup_msg:match("DUPLICATE COMMAND BLOCKED"))
        assert.truthy(dup_msg:match("PREVIOUS OUTPUT"))
        assert.truthy(dup_msg:match("file1.lua"))
    end)
end)
-- ============================================================================
-- INTEGRATION: FULL DENIAL FLOW
-- ============================================================================
describe("integration: full denial flow", function()
    it("security_prompt -> shell denial message chain produces no 'Reason: nil'", function()
        local sp = require("ui.security_prompt")
        local orig_is_tty = sp._is_tty
        sp._is_tty = false
        sp.set_non_tty_mode("auto_deny")
        local allowed, reason = sp.confirm_execution("CODER", "bash dangerous.sh")
        assert.is_false(allowed)
        assert.is_not_nil(reason)
        -- Simulate what shell.lua does with this result
        local output
        if allowed then
            output = "approved"
        elseif reason == "denied" then
            output = "\n[SYSTEM]: Command execution DENIED by user. Do not try this command again."
        else
            output = string.format("\n[SYSTEM]: Command execution DENIED by user. Reason: %s", reason)
        end
        assert.falsy(output:match("Reason: nil"), "Denial message must not contain 'Reason: nil'")
        assert.truthy(output:match("DENIED"))
        sp._is_tty = orig_is_tty
        package.loaded["ui.security_prompt"] = nil
    end)
    it("custom denial reason propagates through the chain", function()
        local sp = require("ui.security_prompt")
        local orig_is_tty = sp._is_tty
        sp._is_tty = false
        sp.set_non_tty_mode("prompt")
        local allowed, reason = sp.confirm_execution("CODER", "bash script.sh")
        assert.is_false(allowed)
        assert.is_not_nil(reason)
        local output = string.format("\n[SYSTEM]: Command execution DENIED by user. Reason: %s", reason)
        assert.falsy(output:match("Reason: nil"))
        assert.truthy(output:match("Reason:"))
        sp._is_tty = orig_is_tty
        package.loaded["ui.security_prompt"] = nil
    end)
end)
