local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local utils = require("utils")
local os = require("os")

describe("Tools: create_file", function()
    local ctx
    local original_write = io.write
    local test_file = "create_file_target.lua"

    before_each(function()
        io.write = function() end
        registry.tools = {}
        tools.init()
        ctx = Context.new({
            PROJECT_ROOT = ".",
            CREATE_BACKUPS = false,
            AGENTS = {
                TEST_AGENT = {
                    allowed_tools = { "*" }
                }
            }
        })
        os.remove(test_file)
    end)

    after_each(function()
        io.write = original_write
        os.remove(test_file)
    end)

    it("should create a new file with given content", function()
        stub(utils, "write_file").returns(true, nil)

        local res = registry.execute("create_file:" .. test_file .. "\nlocal x = 1", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Created/Overwritten file"))
        assert.are.equal("MUTATION_SUCCESS", res.signal)
        assert.are.equal("RECENTLY_MODIFIED", ctx.file_states[test_file])

        utils.write_file:revert()
    end)

    it("should overwrite an existing file", function()
        utils.write_file(test_file, "old content")

        stub(utils, "write_file").returns(true, nil)

        local res = registry.execute("create_file:" .. test_file .. "\nnew content", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Created/Overwritten file"))
        assert.are.equal("MUTATION_SUCCESS", res.signal)

        utils.write_file:revert()
    end)

    it("should return error for invalid syntax", function()
        local res = registry.execute("create_file:no_newline_here", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Invalid create_file syntax"))
    end)
end)
