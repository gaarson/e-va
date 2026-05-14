local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local utils = require("utils")

describe("Tools: cleanup_baks", function()
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

    it("should return success message when cleanup succeeds", function()
        stub(utils, "cleanup_backups").returns(true)

        local res = registry.execute("cleanup_baks", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("All .bak files removed"))

        utils.cleanup_backups:revert()
    end)

    it("should return error message when cleanup fails", function()
        stub(utils, "cleanup_backups").returns(false)

        local res = registry.execute("cleanup_baks", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Failed to clean up .bak files"))

        utils.cleanup_backups:revert()
    end)
end)
