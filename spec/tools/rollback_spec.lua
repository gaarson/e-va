local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local utils = require("utils")
local os = require("os")

describe("Tools: rollback", function()
    local ctx
    local original_write = io.write
    local test_file = "rollback_target.lua"

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
        os.remove(test_file)
        os.remove(test_file .. ".bak")
    end)

    after_each(function()
        io.write = original_write
        os.remove(test_file)
        os.remove(test_file .. ".bak")
    end)

    it("should successfully rollback a file from its .bak version", function()
        utils.write_file(test_file, "modified content")
        utils.write_file(test_file .. ".bak", "original backup content")
        ctx:add_file(test_file, "modified content")

        stub(utils, "restore_backup").returns(true, nil)
        stub(utils, "read_file_range").returns("restored from backup")

        local res = registry.execute("rollback:" .. test_file, ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Rollback successful"))
        assert.are.equal("restored from backup", ctx.knowledge_base[test_file])

        utils.restore_backup:revert()
        utils.read_file_range:revert()
    end)

    it("should return error when rollback fails", function()
        utils.write_file(test_file, "some content")
        ctx:add_file(test_file, "some content")

        stub(utils, "restore_backup").returns(false, "No backup file found")

        local res = registry.execute("rollback:" .. test_file, ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Rollback failed"))

        utils.restore_backup:revert()
    end)
end)
