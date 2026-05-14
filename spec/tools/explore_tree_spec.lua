local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local utils = require("utils")

describe("Tools: explore_tree", function()
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

    it("should execute, update file_tree, and handle explicit depth", function()
        stub(utils, "explore_directory").returns("Directory: /src\n  src/main.lua\n  src/utils/")

        local res = registry.execute("explore_tree:src:2", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Explored directory 'src' %(Depth: 2%)"))
        assert.are.equal("Directory: /src\n  src/main.lua\n  src/utils/", ctx.file_tree)

        utils.explore_directory:revert()
    end)

    it("should default to depth 1 if not specified", function()
        stub(utils, "explore_directory").returns("Directory: /docs\n  docs/readme.md")

        local res = registry.execute("explore_tree:docs", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Depth: 1"))
        assert.are.equal("Directory: /docs\n  docs/readme.md", ctx.file_tree)

        utils.explore_directory:revert()
    end)
end)
