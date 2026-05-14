local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local os = require("os")

describe("Tools: trace_execution", function()
    local ctx
    local original_write = io.write

    before_each(function()
        io.write = function() end
        registry.tools = {}
        tools.init()
        ctx = Context.new({
            PROJECT_ROOT = ".",
            AGENTS = {
                TEST_AGENT = {
                    allowed_tools = { "*" }
                }
            }
        })
    end)

    after_each(function()
        io.write = original_write
    end)

    it("should return trace results for valid input", function()
        local mock_f = { read = function() return "uretprobe:main: func returned 0" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("trace_execution:./my_binary\nuretprobe:./my_binary:main { printf('Ret: %%d', retval); }", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("eBPF TRACE RESULTS"))
        assert.truthy(res.output:match("uretprobe:main: func returned 0"))

        io.popen:revert()
    end)

    it("should return error for invalid syntax", function()
        local res = registry.execute("trace_execution:just_binary_no_script", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Usage:"))
    end)
end)
