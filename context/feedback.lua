-- context/feedback.lua


-- Coder feedback loop extracted from context_flow.lua.

-- All functions take ctx (the context_flow instance) as the first argument.


local M = {}


local history = require("context.history")


-- ============================================================================

-- RECORD TASK SUCCESS

-- ============================================================================

function M.record_task_success(ctx, task_index, summary)

    ctx.coder_feedback.tasks_completed = ctx.coder_feedback.tasks_completed or {}

    table.insert(ctx.coder_feedback.tasks_completed, {

        task_index = task_index,

        summary = summary or "",

        timestamp = os.clock()

    })

    if ctx.execution_plan and ctx.execution_plan[task_index] then

        ctx.task_outcomes[task_index] = {

            status = "SUCCESS",

            summary = summary or "",

            file = ctx.execution_plan[task_index].file

        }

    end

end


-- ============================================================================

-- RECORD TASK FAILURE

-- ============================================================================

function M.record_task_failure(ctx, task_index, error_msg)

    ctx.coder_feedback.tasks_failed = ctx.coder_feedback.tasks_failed or {}

    table.insert(ctx.coder_feedback.tasks_failed, {

        task_index = task_index,

        error = error_msg or "",

        timestamp = os.clock()

    })

    if ctx.execution_plan and ctx.execution_plan[task_index] then

        ctx.task_outcomes[task_index] = {

            status = "FAILED",

            error = error_msg or "",

            file = ctx.execution_plan[task_index].file

        }

    end

end


-- ============================================================================

-- RECORD ERROR

-- ============================================================================

function M.record_error(ctx, error_msg)

    ctx.coder_feedback.errors_encountered = ctx.coder_feedback.errors_encountered or {}

    table.insert(ctx.coder_feedback.errors_encountered, {

        error = error_msg or "",

        timestamp = os.clock()

    })

end


-- ============================================================================

-- RECORD DEVIATION

-- ============================================================================

function M.record_deviation(ctx, note)

    ctx.coder_feedback.plan_deviations = ctx.coder_feedback.plan_deviations or {}

    table.insert(ctx.coder_feedback.plan_deviations, {

        note = note or "",

        timestamp = os.clock()

    })

end


-- ============================================================================

-- ADD RECOMMENDATION

-- ============================================================================

function M.add_recommendation(ctx, rec)

    ctx.coder_feedback.recommendations = ctx.coder_feedback.recommendations or {}

    table.insert(ctx.coder_feedback.recommendations, {

        recommendation = rec or "",

        timestamp = os.clock()

    })

end


-- ============================================================================

-- GENERATE FEEDBACK REPORT

-- ============================================================================

function M.generate_feedback_report(ctx)

    local cfg = ctx.config.HANDOFF or {}

    local max_tokens = cfg.max_feedback_tokens or 3000

    local div = ctx.flow_config.token_estimation.chars_per_token

    local max_chars = math.floor(max_tokens * div)

    local parts = {}

    table.insert(parts, "<coder_feedback_report>")


    local function add_section(tag, items, formatter)

        if not items or #items == 0 then return end

        table.insert(parts, string.format("<%s>", tag))

        for _, item in ipairs(items) do

            local line = formatter(item)

            if line then table.insert(parts, line) end

        end

        table.insert(parts, string.format("</%s>", tag))

    end


    add_section("tasks_completed", ctx.coder_feedback.tasks_completed, function(item)

        return string.format("- Step %d: %s (%s)", item.task_index, item.summary or "completed", item.file or "unknown file")

    end)

    add_section("tasks_failed", ctx.coder_feedback.tasks_failed, function(item)

        return string.format("- Step %d: FAILED - %s", item.task_index, item.error or "unknown error")

    end)

    add_section("errors_encountered", ctx.coder_feedback.errors_encountered, function(item)

        return "- " .. (item.error or "")

    end)

    add_section("plan_deviations", ctx.coder_feedback.plan_deviations, function(item)

        return "- " .. (item.note or "")

    end)

    add_section("recommendations", ctx.coder_feedback.recommendations, function(item)

        return "- " .. (item.recommendation or "")

    end)


    table.insert(parts, "</coder_feedback_report>")

    local report = table.concat(parts, "\n")

    -- Truncate if over budget

    if #report > max_chars then

        report = report:sub(1, max_chars) .. "\n... [FEEDBACK TRUNCATED]"

    end

    return report

end


-- ============================================================================

-- INJECT FEEDBACK AS MESSAGE

-- ============================================================================

function M.inject_feedback_as_message(ctx, agent_name, feedback_text)

    if not feedback_text or feedback_text == "" then return end

    history.add_message(ctx, agent_name, "system", "[CODER FEEDBACK]\n" .. feedback_text)

end


return M