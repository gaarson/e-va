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
    registry.register("task_complete", "Advances execution plan by one step, or signals ALL tasks complete if at last step. If no execution_plan exists, immediately signals PIPELINE_NEXT_STAGE.", "||| COMMAND |||\ntask_complete\n||| END_COMMAND |||\n\nNo arguments required.\n\nBEHAVIOR:\n- If execution_plan exists and current_task_index < total: advances to next step, reports new target file.\n- If at last step: generates completion report (all steps + modified files), returns PIPELINE_NEXT_STAGE.\n- If NO execution_plan: immediately returns PIPELINE_NEXT_STAGE (Task marked as complete).\n- Valid without args (no_arg_ok=true).", function(args, ctx, agent_name)
        -- FIX: Ensure execution_plan is initialized to prevent crash if nil
        if not ctx.execution_plan then
            ctx.execution_plan = {}
        end
        if #ctx.execution_plan > 0 then
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
    TASK_COMPLETE_MANIFEST, true)
end
return { register = register }