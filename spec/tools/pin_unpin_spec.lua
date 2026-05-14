local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")

describe("Tools: pin/unpin", function()
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

    it("should pin a file that is in memory", function()
        ctx:add_file("target.lua", "some data")

        local res = registry.execute("pin:target.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Pinned 'target.lua'"))
        assert.is_true(ctx.pinned_files["target.lua"])
    end)

    it("should fail to pin a file not in memory", function()
        local res = registry.execute("pin:missing.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("not in memory"))
    end)

    it("should unpin a previously pinned file", function()
        ctx:add_file("target.lua", "some data")
        ctx:pin_file("target.lua")

        local res = registry.execute("unpin:target.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Unpinned 'target.lua'"))
        assert.is_nil(ctx.pinned_files["target.lua"])
    end)

    it("should fail to unpin a file that was not pinned", function()
        ctx:add_file("normal.lua", "data")

        local res = registry.execute("unpin:normal.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("was not pinned"))
    end)
end)
