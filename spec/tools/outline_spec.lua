local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local utils = require("utils")

describe("Tools: outline", function()
    local ctx
    local original_write = io.write
    local test_file = "outline_test_target.lua"

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
        utils.write_file(test_file, "local function my_func()\nend\nlocal function another()\nend")
    end)

    after_each(function()
        io.write = original_write
        os.remove(test_file)
    end)

    it("should return a valid outline for a file with functions", function()
        local mock_f = { read = function() return "1:local function my_func()\n2:local function another()" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("outline:" .. test_file, ctx, "TEST_AGENT")

        assert.truthy(res.output:match("SYSTEM OUTLINE FOR"))
        assert.truthy(res.output:match("my_func"))

        io.popen:revert()
    end)

    it("should return empty message when no signatures found", function()
        local mock_f = { read = function() return "" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("outline:" .. test_file, ctx, "TEST_AGENT")

        assert.truthy(res.output:match("empty or no valid signatures"))

        io.popen:revert()
    end)

    it("should return error for missing file", function()
        local res = registry.execute("outline:totally_missing_file.lua", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("File not found"))
    end)
end)
