local registry = require("tool_registry")
local logger = require("logger")

describe("Tool Registry Edge Cases & Manifest Generation", function()
    before_each(function()
        registry.tools = {}
    end)

    it("should reject non-function handlers", function()
        stub(logger, "error")
        registry.register("bad_tool", "desc", "usage", "not a function")
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

    it("should dynamically generate a tool manifest from registered tools", function()
        registry.register("dummy_tool", "Does something dummy", "<cmd>dummy_tool:arg</cmd>", function() end)

        local manifest = registry.generate_tool_manifest({"dummy_tool"})

        assert.truthy(manifest:match("TOOLCHAIN INTERFACE"), "Must include the header")
        assert.truthy(manifest:match("### Tool: `<cmd>dummy_tool</cmd>`"), "Must generate markdown header for the tool")
        assert.truthy(manifest:match("Does something dummy"), "Must include description")
        assert.truthy(manifest:match("<cmd>dummy_tool:arg</cmd>"), "Must include usage example")
    end)

    it("should grant and list ALL_TOOLS if allowed_tools contains '*'", function()
        registry.register("tool_a", "A", "use A", function() end)
        registry.register("tool_b", "B", "use B", function() end)

        local manifest = registry.generate_tool_manifest({"*"})

        assert.truthy(manifest:match("Admin privileges granted"))
        assert.truthy(manifest:match("tool_a"))
        assert.truthy(manifest:match("tool_b"))
    end)

    it("should warn if agent has NO tools assigned", function()
        local manifest1 = registry.generate_tool_manifest({})
        local manifest2 = registry.generate_tool_manifest(nil)

        assert.truthy(manifest1:match("NO tools assigned"))
        assert.truthy(manifest2:match("NO tools assigned"))
    end)
end)
