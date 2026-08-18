local TASK_COMPLETE_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output_str)
        return output_str
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "task_complete: Signals that the current task is finished.",
}
local function register(registry)
    registry.register("task_complete", "Signal completion of the current task step", "||| COMMAND |||\ntask_complete\n||| END_COMMAND |||", function(args, ctx, agent_name)
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
                -- Mark all tasks as done by advancing index past the last one
                ctx.current_task_index = #ctx.execution_plan + 1
                -- Build completion report for the next agent
                local report_parts = {}
                table.insert(report_parts, "\n[SYSTEM]: ALL TASKS COMPLETE. Execution plan finished successfully.")
                table.insert(report_parts, "")
                table.insert(report_parts, "Completed steps:")
                for i, task in ipairs(ctx.execution_plan) do
                    table.insert(report_parts, string.format("  %d. %s — %s", i, tostring(task.file), tostring(task.instruction)))
                end
                -- List modified files
                local modified = {}
                for path, state in pairs(ctx.file_states) do
                    if state == "MODIFIED" or state == "CREATED" then
                        table.insert(modified, string.format("  - %s (%s)", path, state))
                    end
                end
                if #modified > 0 then
                    table.insert(report_parts, "")
                    table.insert(report_parts, "Files modified:")
                    table.sort(modified)
                    for _, m in ipairs(modified) do
                        table.insert(report_parts, m)
                    end
                end
                table.insert(report_parts, "")
                table.insert(report_parts, "Ready for architect analysis.")
                return {
                    output = table.concat(report_parts, "\n"),
                    signal = "PIPELINE_NEXT_STAGE"
                }
            end
        else
            return { output = "\n[SYSTEM]: Task marked as complete.", signal = "PIPELINE_NEXT_STAGE" }
        end
    end,
    nil,
    TASK_COMPLETE_MANIFEST)
end
return { register = register }