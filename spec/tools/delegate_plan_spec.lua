local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")

describe("Tools: delegate_plan", function()
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

    it("should parse valid JSON with plan and memo", function()
        local res = registry.execute('delegate_plan:{"plan": [{"file": "test.c", "instruction": "fix"}], "memo": "Be careful"}', ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Plan delegated successfully"))
        assert.are.equal("PIPELINE_NEXT_STAGE", res.signal)
        assert.is_table(ctx.execution_plan)
        assert.are.equal("Be careful", ctx.handoff_memo)
    end)

    it("should handle fallback array format", function()
        local res = registry.execute('delegate_plan:[{"file": "test2.c", "instruction": "fix2"}]', ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Plan delegated successfully"))
        assert.is_table(ctx.execution_plan)
    end)

    it("should return error for invalid JSON", function()
        local res = registry.execute('delegate_plan:{invalid json}', ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Invalid JSON plan format"))
        assert.is_nil(res.signal)
    end)
end)
