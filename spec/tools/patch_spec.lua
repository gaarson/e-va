local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")
local patcher = require("patcher")
local utils = require("utils")

describe("Tools: patch", function()
    local ctx
    local original_write = io.write

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
    end)

    after_each(function()
        io.write = original_write
    end)

    it("should return error for invalid syntax", function()
        local res = registry.execute("patch:invalid_syntax", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Invalid patch syntax"))
    end)

    it("should succeed with state change on valid patch", function()
        ctx:add_file("target.lua", "local old_code = 1")

        stub(patcher, "apply_patch").returns(true, "local new_code = 2", 1, nil)
        stub(utils, "write_file").returns(true, nil)

        local res = registry.execute("patch:target.lua\n<<<<<<< SEARCH\nlocal old_code = 1\n=======\nlocal new_code = 2\n>>>>>>> REPLACE", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("%[SUCCESS%]"))
        assert.are.equal("RECENTLY_MODIFIED", ctx.file_states["target.lua"])
        assert.are.equal("MUTATION_SUCCESS", res.signal)

        patcher.apply_patch:revert()
        utils.write_file:revert()
    end)

    it("should return error on patch failure", function()
        ctx:add_file("target.lua", "original_content")

        stub(patcher, "apply_patch").returns(false, nil, 0, "fuzzy match failed")

        local res = registry.execute("patch:target.lua\n<<<<<<< SEARCH\nwrong\n=======\nright\n>>>>>>> REPLACE", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("PATCH FAILED"))
        assert.are.equal("READ", ctx.file_states["target.lua"])

        patcher.apply_patch:revert()
    end)

    it("should return error if file not found", function()
        local res = registry.execute("patch:missing_file.lua\n<<<<<<< SEARCH\nx\n=======\ny\n>>>>>>> REPLACE", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("File not found"))
    end)
end)