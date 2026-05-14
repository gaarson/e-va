local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")

describe("Tools: search", function()
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

    it("should perform a valid search and return results", function()
        local mock_f = { read = function() return "match_line_here" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("search:my_function", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("SEARCH RESULTS"))
        assert.truthy(res.output:match("match_line_here"))

        io.popen:revert()
    end)

    it("should skip duplicate searches", function()
        local mock_f = { read = function() return "result" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res1 = registry.execute("search:duplicate_term", ctx, "TEST_AGENT")
        assert.truthy(res1.output:match("result"))

        local res2 = registry.execute("search:duplicate_term", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("Skipped duplicate"))

        io.popen:revert()
    end)

    it("should return error for empty query", function()
        local res = registry.execute("search:  ", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Empty search query"))
    end)
end)
