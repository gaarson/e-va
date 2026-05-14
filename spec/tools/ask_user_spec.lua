local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")

describe("Tools: ask_user", function()
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

    it("should return user answer when provided", function()
        stub(io, "read").returns("Yes, proceed with the fix")

        local res = registry.execute("ask_user:Is this logic correct?", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("USER REPLY"))
        assert.truthy(res.output:match("Yes, proceed with the fix"))

        io.read:revert()
    end)

    it("should return skip message when user presses Enter", function()
        stub(io, "read").returns("")

        local res = registry.execute("ask_user:Should I refactor this?", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("No response provided by user"))

        io.read:revert()
    end)
end)
