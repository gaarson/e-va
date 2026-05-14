local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")

describe("Tools: shell", function()
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

    it("should execute safe commands and return output", function()
        local res = registry.execute("shell:echo 'hello world'", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("hello world"))
    end)

    it("should deny unsafe commands when user says no", function()
        stub(io, "read").returns("n")

        local res = registry.execute("shell:rm -rf /tmp/test", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("DENIED by user"))

        io.read:revert()
    end)

    it("should trigger circuit breaker after 3 consecutive failures", function()
        ctx.test_failures = 2

        local res = registry.execute("shell:echo 'Error: build failed' && false", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("CIRCUIT BREAKER TRIGGERED"))
        assert.are.equal(0, ctx.test_failures)
    end)
end)
