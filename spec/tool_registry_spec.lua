local registry = require("tool_registry")
local logger = require("logger")

describe("Tool Registry Edge Cases", function()
    it("should reject non-function handlers", function()
        stub(logger, "error")
        registry.register("bad_tool", "desc", "not a function")
        assert.is_nil(registry.tools["bad_tool"])
        assert.stub(logger.error).was_called()
        logger.error:revert()
    end)

    it("should handle empty or unknown commands", function()
        local ctx = { config = { AGENTS = { TEST = {} } } }
        local res_empty = registry.execute("", ctx, "TEST")
        assert.truthy(res_empty.output:match("Malformed command"))

        local res_unknown = registry.execute("fake_tool:args", ctx, "TEST")
        assert.truthy(res_unknown.output:match("Unknown command"))
    end)
end)
