local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local utils = require("utils")

describe("Tools: read_chunk", function()
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

    it("should read a valid line range", function()
        stub(utils, "read_file_numbered").returns("10 | local x = 1\n11 | local y = 2", 2)

        local res = registry.execute("read_chunk:test.lua:10-11", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Chunk of 'test%.lua' %(Lines 10%-11%)"))
        assert.truthy(res.output:match("local x = 1"))

        utils.read_file_numbered:revert()
    end)

    it("should handle path: prefix syntax", function()
        stub(utils, "read_file_numbered").returns("5 | data", 1)

        local res = registry.execute("read_chunk:path:test.lua:5-5", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Chunk"))

        utils.read_file_numbered:revert()
    end)

    it("should return error for invalid syntax", function()
        local res = registry.execute("read_chunk:invalid_syntax", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Usage:"))
    end)

    it("should return error if file cannot be read", function()
        stub(utils, "read_file_numbered").returns(nil, "error reading file")

        local res = registry.execute("read_chunk:missing.lua:1-10", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Could not read chunk"))

        utils.read_file_numbered:revert()
    end)
end)