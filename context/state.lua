-- context/state.lua
-- State persistence (snapshot/load/reset) extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local json = require("JSON")
local utils = require("utils")
-- ============================================================================
-- SNAPSHOT
-- ============================================================================
function M.snapshot(ctx)
    return json:encode({
        knowledge_base = ctx.knowledge_base,
        file_access_rank = ctx.file_access_rank,
        global_access_counter = ctx.global_access_counter,
        file_states = ctx.file_states,
        search_history = ctx.search_history,
        history = ctx.history,
        thoughts = ctx.thoughts,
        execution_plan = ctx.execution_plan,
        current_task_index = ctx.current_task_index,
        promoted_files = ctx.promoted_files,
        pinned_files = ctx.pinned_files,
        last_actions = ctx.last_actions,
        handoff_memo = ctx.handoff_memo,
        test_failures = ctx.test_failures,
        turn_requested_files = ctx.turn_requested_files,
        calibration_data = ctx.calibration_data,
        coder_feedback = ctx.coder_feedback,
        task_outcomes = ctx.task_outcomes,
        executed_commands = ctx.executed_commands
    })
end
-- ============================================================================
-- LOAD FROM SNAPSHOT
-- ============================================================================
function M.load_from_snapshot(ctx, json_str)
    local ok, state = pcall(function() return json:decode(json_str) end)
    if not ok or not state then return false, "Corrupted JSON" end
    ctx.knowledge_base = state.knowledge_base or {}
    ctx.file_access_rank = state.file_access_rank or {}
    ctx.global_access_counter = state.global_access_counter or 0
    ctx.file_states = state.file_states or {}
    ctx.search_history = state.search_history or {}
    ctx.history = state.history or {}
    ctx.thoughts = state.thoughts or {}
    ctx.execution_plan = state.execution_plan or {}
    ctx.current_task_index = state.current_task_index or 1
    ctx.pinned_files = state.pinned_files or {}
    ctx.last_actions = state.last_actions or {}
    ctx.handoff_memo = state.handoff_memo
    ctx.test_failures = state.test_failures or 0
    ctx.turn_requested_files = state.turn_requested_files or {}
    ctx.promoted_files = state.promoted_files or {}
    ctx.calibration_data = state.calibration_data or {}
    ctx.coder_feedback = state.coder_feedback or {
        tasks_completed = {},
        tasks_failed = {},
        errors_encountered = {},
        plan_deviations = {},
        recommendations = {}
    }
    ctx.task_outcomes = state.task_outcomes or {}
    ctx.executed_commands = state.executed_commands or {}
    return true
end
-- ============================================================================
-- RESET
-- ============================================================================
function M.reset(ctx)
    ctx.task_summary = ""
    ctx.history = {}
    ctx.knowledge_base = {}
    ctx.file_states = {}
    ctx.pinned_files = {}
    ctx.search_history = {}
    ctx.thoughts = {}
    ctx.last_actions = {}
    ctx.turn_requested_files = {}
    ctx.promoted_files = {}
    ctx.recent_tool_outputs = {}
    ctx.global_access_counter = 0
    ctx.file_access_rank = {}
    ctx.execution_plan = {}
    ctx.current_task_index = 1
    ctx.handoff_memo = nil
    ctx.images = {}
    ctx.images_loaded = false
    ctx.last_sent_image_hashes = {}
    ctx.test_failures = 0
    ctx.consecutive_recoveries = 0
    ctx.file_tree = nil
    ctx.calibration_data = {}
    -- Reset feedback tracking
    ctx.coder_feedback = {
        tasks_completed = {},
        tasks_failed = {},
        errors_encountered = {},
        plan_deviations = {},
        recommendations = {}
    }
    ctx.task_outcomes = {}
    ctx.executed_commands = {}
end
-- ============================================================================
-- UPDATE SUMMARY
-- ============================================================================
function M.update_summary(ctx, new_summary)
    ctx.task_summary = utils.trim(new_summary)
    M.add_action(ctx, "SUMMARY_UPDATE", "Updated task summary")
end
-- ============================================================================
-- ADD ACTION
-- ============================================================================
function M.add_action(ctx, action_type, summary)
    table.insert(ctx.last_actions, { type = action_type, summary = summary })
    if #ctx.last_actions > 10 then table.remove(ctx.last_actions, 1) end
end
return M
