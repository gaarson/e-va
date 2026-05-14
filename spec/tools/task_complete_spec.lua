local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")

describe("Tools: task_complete", function()
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

    it("should increment task index when plan has remaining steps", function()
        ctx.execution_plan = {
            { file = "file1.lua", instruction = "step 1" },
            { file = "file2.lua", instruction = "step 2" }
        }
        ctx.current_task_index = 1

        local res = registry.execute("task_complete", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Step 1/2 complete"))
        assert.is_nil(res.signal)
        assert.are.equal(2, ctx.current_task_index)
    end)

    it("should send PIPELINE_NEXT_STAGE when plan is exhausted", function()
        ctx.execution_plan = {
            { file = "file1.lua", instruction = "step 1" }
        }
        ctx.current_task_index = 1

        local res = registry.execute("task_complete", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("All steps in the execution plan are complete"))
        assert.are.equal("PIPELINE_NEXT_STAGE", res.signal)
    end)

    it("should send PIPELINE_NEXT_STAGE for empty plan", function()
        ctx.execution_plan = nil

        local res = registry.execute("task_complete", ctx, "TEST_AGENT")

        assert.truthy(res.output:match("Task marked as complete"))
        assert.are.equal("PIPELINE_NEXT_STAGE", res.signal)
    end)
end)
