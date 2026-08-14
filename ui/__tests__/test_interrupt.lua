describe("ui/interrupt", function()
    local interrupt = require("ui.interrupt")
    local input = require("ui.input")

    -- ============================================================
    -- sanitize_input
    -- ============================================================
    describe("sanitize_input", function()
        it("strips control chars 0x00-0x08", function()
            local result = interrupt.sanitize_input("\x00\x01\x02hello")
            assert.equals("hello", result)
        end)

        it("keeps tab and newline", function()
            local result = interrupt.sanitize_input("a\tb\nc")
            assert.equals("a\tb\nc", result)
        end)

        it("keeps UTF-8 bytes", function()
            local result = interrupt.sanitize_input("привет")
            assert.equals("привет", result)
        end)

        it("returns empty for nil", function()
            assert.equals("", interrupt.sanitize_input(nil))
        end)

        it("returns empty for non-string", function()
            assert.equals("", interrupt.sanitize_input(123))
        end)

        it("strips bytes 0x0B-0x0C and 0x0E-0x1F", function()
            local result = interrupt.sanitize_input("a\x0Bb\x0Cc\x0Ed\x1F")
            assert.equals("abcd", result)
        end)
    end)

    -- ============================================================
    -- handle_interruption_with_capture
    -- ============================================================
    describe("handle_interruption_with_capture", function()
        local original_read_text
        local original_sleep

        local original_os_execute
        before_each(function()
            original_read_text = input.read_text
            original_sleep = require("socket").sleep
            original_os_execute = os.execute
            os.execute = function(cmd) return 0 end
        end)
        after_each(function()
            input.read_text = original_read_text
            require("socket").sleep = original_sleep
            os.execute = original_os_execute
        end)

        it("returns nil for empty input", function()
            input.read_text = function(prompt, opts) return "" end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            assert.is_nil(result)
        end)

        it("returns nil for whitespace-only", function()
            input.read_text = function(prompt, opts) return "   " end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            assert.is_nil(result)
        end)

        it("returns sanitized text", function()
            input.read_text = function(prompt, opts) return "  hello world  " end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            assert.equals("  hello world  ", result)
        end)

        it("returns nil when read_text returns nil", function()
            input.read_text = function(prompt, opts) return nil end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            assert.is_nil(result)
        end)
        it("returns '/discard' when user types /discard", function()
            input.read_text = function(prompt, opts) return "/discard" end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            assert.equals("/discard", result)
        end)
        it("returns '/discard' with trailing whitespace trimmed by caller", function()
            input.read_text = function(prompt, opts) return "  /discard  " end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            -- sanitize_input preserves whitespace, so the raw string is returned
            -- The caller in agent/turn.lua does had_input:lower():sub(1, 8) == "/discard"
            -- but with leading spaces it won't match. However the function returns the
            -- sanitized string as-is (trim is only used for emptiness check).
            assert.equals("  /discard  ", result)
        end)
        it("strips null bytes from /discard input", function()
            input.read_text = function(prompt, opts) return "/discard\x00" end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            assert.equals("/discard", result)
        end)
        it("strips control chars from /discard input", function()
            input.read_text = function(prompt, opts) return "/dis\x01card" end
            require("socket").sleep = function(t) end
            local result = interrupt.handle_interruption_with_capture("test_agent")
            assert.equals("/discard", result)
        end)
    end)

    -- ============================================================
    -- should_abort
    -- ============================================================
    describe("should_abort", function()
        it("returns false below limit", function()
            assert.is_false(interrupt.should_abort(0))
            assert.is_false(interrupt.should_abort(2))
        end)

        it("returns true at limit", function()
            assert.is_true(interrupt.should_abort(3))
        end)

        it("returns true above limit", function()
            assert.is_true(interrupt.should_abort(5))
        end)
    end)

    -- ============================================================
    -- MAX_INTERRUPTION_RETRIES
    -- ============================================================
    describe("MAX_INTERRUPTION_RETRIES", function()
        it("equals 3", function()
            assert.equals(3, interrupt.MAX_INTERRUPTION_RETRIES)
        end)
    end)
end)