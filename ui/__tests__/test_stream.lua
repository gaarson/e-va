describe("ui/stream", function()
    local stream = require("ui.stream")

    -- ============================================================
    -- stream_token_printer: basic structure
    -- ============================================================
    describe("stream_token_printer", function()
        it("returns a callable table with on_token and flush methods", function()
            local printer = stream.stream_token_printer({ is_reasoning = false })
            assert.is_table(printer)
            assert.is_function(printer.on_token)
            assert.is_function(printer.flush)
            -- Should be callable via metatable __call
            assert.is_truthy(getmetatable(printer).__call)
        end)

        it("works with nil agent_cfg", function()
            local printer = stream.stream_token_printer(nil)
            assert.is_table(printer)
            assert.is_function(printer.on_token)
            assert.is_function(printer.flush)
        end)

        it("works with reasoning agent config", function()
            local printer = stream.stream_token_printer({ is_reasoning = true })
            assert.is_table(printer)
            assert.is_function(printer.on_token)
            assert.is_function(printer.flush)
        end)

        it("on_token accepts a string token without error", function()
            local printer = stream.stream_token_printer({ is_reasoning = false })
            -- Should not raise
            printer.on_token("hello ")
            printer.on_token("world")
            printer:flush()
        end)

        it("callable form works the same as on_token", function()
            local printer = stream.stream_token_printer({ is_reasoning = false })
            -- Call via metatable
            printer("test token")
            printer:flush()
        end)
    end)

    -- ============================================================
    -- flush_stream_buffer
    -- ============================================================
    describe("flush_stream_buffer", function()
        it("handles a printer object with flush method", function()
            local mock_printer = {
                flush_called = false,
                flush = function(self)
                    self.flush_called = true
                end
            }
            local buf, flag = stream.flush_stream_buffer(mock_printer)
            assert.equals("", buf)
            assert.equals(false, flag)
            assert.is_true(mock_printer.flush_called)
        end)

        it("handles a non-empty string buffer", function()
            local buf, flag = stream.flush_stream_buffer("some text", false)
            assert.equals("some text", buf)
            assert.equals(false, flag)
        end)

        it("handles a non-empty string buffer with in_thought flag", function()
            local buf, flag = stream.flush_stream_buffer("thinking text", true)
            assert.equals("thinking text", buf)
            assert.equals(true, flag)
        end)

        it("handles nil input without crashing", function()
            local buf, flag = stream.flush_stream_buffer(nil)
            assert.equals("", buf)
            assert.equals(false, flag)
        end)

        it("handles empty string without crashing", function()
            local buf, flag = stream.flush_stream_buffer("")
            assert.equals("", buf)
            assert.equals(false, flag)
        end)

        it("handles a table without flush method gracefully", function()
            local plain_table = { foo = "bar" }
            local buf, flag = stream.flush_stream_buffer(plain_table)
            assert.equals("", buf)
            assert.equals(false, flag)
        end)
    end)

    -- ============================================================
    -- Tag detection behavior (via on_token with reasoning)
    -- ============================================================
    describe("tag detection", function()
        it("reasoning printer does NOT start in thought mode", function()
            local printer = stream.stream_token_printer({ is_reasoning = true })
            -- Text before any thinking tag must NOT be gray
            printer.on_token("some reasoning text")
            printer:flush()
        end)

        it("non-reasoning printer handles thinking tag in stream", function()
            local printer = stream.stream_token_printer({ is_reasoning = false })
            -- Simulate a stream that contains the opening tag
            printer.on_token("Hello <thinking>")
            printer.on_token("internal thoughts here")
            printer.on_token("</thinking> final answer")
            printer:flush()
        end)

        it("handles partial tag across token boundaries", function()
            local printer = stream.stream_token_printer({ is_reasoning = false })
            -- Split tag across two tokens
            printer.on_token("prefix <thi")
            printer.on_token("nking> thought content")
            printer.on_token("</thin")
            printer.on_token("g> result")
            printer:flush()
        end)

        it("handles multiple thinking blocks in sequence", function()
            local printer = stream.stream_token_printer({ is_reasoning = false })
            printer.on_token("<thinking>first</thinking>")
            printer.on_token("middle text")
            printer.on_token("<thinking>second</thinking>")
            printer.on_token("end")
            printer:flush()
        end)
    end)
end)