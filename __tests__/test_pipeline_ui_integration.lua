describe("Pipeline UI Integration - End-to-End", function()
    local pipeline_ui = require("ui.pipeline_ui")
    local command_parser = require("ui.command_parser")
    local strings = require("utils.strings")
    describe("pipeline_ui.parse_command() delegation", function()
        it("should delegate to command_parser.parse()", function()
            local result = pipeline_ui.parse_command("/go", nil)
            assert.equals("NEXT_STAGE", result.action)
        end)
        it("should pass config through for /mode", function()
            local config = { PIPELINE = { { stage = "CODER", mode = "sequential" } } }
            local result = pipeline_ui.parse_command("/mode CODER", config)
            assert.equals("SWITCH_STAGE", result.action)
            assert.equals(1, result.target_idx)
        end)
        it("should handle nil input", function()
            local result = pipeline_ui.parse_command(nil, nil)
            assert.equals("ABORT", result.action)
        end)
        it("should handle empty string", function()
            local result = pipeline_ui.parse_command("", nil)
            assert.equals("SKIP", result.action)
        end)
    end)
    describe("command_parser.COMMANDS completeness", function()
        it("should have all documented commands", function()
            assert.truthy(command_parser.COMMANDS["/go"])
            assert.truthy(command_parser.COMMANDS["/back"])
            assert.truthy(command_parser.COMMANDS["/exit"])
            assert.truthy(command_parser.COMMANDS["/status"])
            assert.truthy(command_parser.COMMANDS["/help"])
            assert.truthy(command_parser.COMMANDS["/messages"])
        end)
        it("should have exactly 6 static commands", function()
            local count = 0
            for k, _ in pairs(command_parser.COMMANDS) do
                count = count + 1
            end
            assert.equals(6, count)
        end)
    end)
    describe("HELP text consistency", function()
        it("should mention all commands in HELP_TEXT", function()
            local help = command_parser.HELP_TEXT
            assert.truthy(help:find("/go"))
            assert.truthy(help:find("/back"))
            assert.truthy(help:find("/exit"))
            assert.truthy(help:find("/mode"))
            assert.truthy(help:find("/status"))
            assert.truthy(help:find("/help"))
            assert.truthy(help:find("/messages"))
        end)
    end)
    describe("strings.trim() is the single source of truth for whitespace", function()
        -- Verify that the trim function used by both parser and pipeline dispatch
        -- produces consistent results
        local test_cases = {
            { input = "/go", expected = "/go" },
            { input = "  /go  ", expected = "/go" },
            { input = "\t/go\t", expected = "/go" },
            { input = "\n/go\n", expected = "/go" },
            { input = "\r\n/go\r\n", expected = "/go" },
            { input = " \t\n\r /status \r\n\t ", expected = "/status" },
            { input = "", expected = "" },
            { input = "   ", expected = "" },
        }
        for _, tc in ipairs(test_cases) do
            it("should trim '" .. tostring(tc.input):gsub("%c", "\\n") .. "' -> '" .. tc.expected .. "'", function()
                assert.equals(tc.expected, strings.trim(tc.input))
            end)
        end
    end)
    describe("Pipeline dispatch consistency check", function()
        -- This test verifies that the early-exit check in pipeline.lua
        -- and the command_parser produce consistent results
        local function pipeline_early_check(user_input)
            -- From agent/pipeline.lua line 77-79
            return not user_input or strings.trim(user_input) == "" or strings.trim(user_input) == "/exit"
        end
        it("should catch /exit in early check, not in parser", function()
            assert.is_true(pipeline_early_check("/exit"))
            -- Parser would also catch it, but early check takes precedence
            local parsed = command_parser.parse("/exit", nil)
            assert.equals("ABORT", parsed.action)
        end)
        it("should NOT catch /go in early check", function()
            assert.is_false(pipeline_early_check("/go"))
        end)
        it("should NOT catch /status in early check", function()
            assert.is_false(pipeline_early_check("/status"))
        end)
        it("should catch nil in early check", function()
            assert.is_true(pipeline_early_check(nil))
        end)
        it("should catch empty in early check", function()
            assert.is_true(pipeline_early_check(""))
        end)
        it("should catch whitespace-only in early check", function()
            assert.is_true(pipeline_early_check("   "))
        end)
    end)
end)