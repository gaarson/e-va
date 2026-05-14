local function register(registry)
    registry.register("task_complete", "Signal completion of the current task step", "<cmd>task_complete</cmd>", function(args, ctx, agent_name)
        if ctx.execution_plan and #ctx.execution_plan > 0 then
            if ctx.current_task_index < #ctx.execution_plan then
                local old_idx = ctx.current_task_index
                ctx.current_task_index = ctx.current_task_index + 1
                local next_task = ctx.execution_plan[ctx.current_task_index]

                return {
                    output = string.format("\n[SYSTEM]: Step %d/%d complete. Moving to step %d. New target loaded: %s",
                                           old_idx, #ctx.execution_plan, ctx.current_task_index, tostring(next_task.file)),
                    signal = nil
                }
            else
                return {
                    output = "\n[SYSTEM]: All steps in the execution plan are complete. Ending stage.",
                    signal = "PIPELINE_NEXT_STAGE"
                }
            end
        else
            return { output = "\n[SYSTEM]: Task marked as complete.", signal = "PIPELINE_NEXT_STAGE" }
        end
    end)
end

return { register = register }