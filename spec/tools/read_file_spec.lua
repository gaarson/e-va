local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local utils = require("utils")

describe("Tools: read_file", function()
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

    it("should load a new file into memory", function()
        stub(utils, "read_file_range").returns("local x = 1")

        local res = registry.execute("read_file:new_module.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Successfully loaded 'new_module.lua'"))
        assert.truthy(ctx.knowledge_base["new_module.lua"])

        utils.read_file_range:revert()
    end)

    it("should warn if file is already in memory", function()
        ctx:add_file("existing.lua", "local y = 2")

        local res = registry.execute("read_file:existing.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("ALREADY in memory"))
        assert.falsy(res.output:match("Successfully loaded"))
    end)

    it("should return error for missing file", function()
        stub(utils, "read_file_range").returns(nil, "No such file or directory")

        local res = registry.execute("read_file:ghost.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("%[ERROR%]"))
        assert.falsy(ctx.knowledge_base["ghost.lua"])

        utils.read_file_range:revert()
    end)
end)
