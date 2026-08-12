-- context/state.lua
-- State persistence (snapshot/load/reset) extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local json = require("JSON")
local utils = require("utils")
-- ============================================================================
-- SNAPSHOT
-- ============================================================================
-- DESIGN DECISION: knowledge_base is NOT serialized into the snapshot.
-- Including full file contents makes snapshots huge and slow to serialize/deserialize.
-- Instead, we store only the list of known file paths. On restore (load_from_snapshot),
-- files are re-read from disk lazily when accessed. This keeps snapshots lightweight
-- and ensures the agent always works with the latest on-disk file versions.
-- ============================================================================
-- VALIDATE SNAPSHOT
-- ============================================================================
function M.validate_snapshot(state)
    if type(state) ~= "table" then
        return false, "Snapshot root is not a table"
    end
    local required_tables = {
        "history", "file_states", "thoughts", "execution_plan",
        "last_actions", "turn_requested_files", "calibration_data",
        "coder_feedback", "task_outcomes", "executed_commands",
        "file_access_rank", "search_history", "pinned_files",
        "promoted_files"
    }
    for _, field in ipairs(required_tables) do
        if state[field] ~= nil and type(state[field]) ~= "table" then
            return false, string.format("Field '%s' must be a table, got %s", field, type(state[field]))
        end
    end
    return true
end
-- ============================================================================
-- SNAPSHOT
-- ============================================================================
function M.snapshot(ctx)
    -- Store only file paths, not full contents
    local kb_paths = {}
    if ctx.knowledge_base then
        for path, _ in pairs(ctx.knowledge_base) do
            table.insert(kb_paths, path)
        end
    end
    local ok, result = pcall(function()
        return json:encode({
            version = 2,
            knowledge_base_paths = kb_paths,
            task_summary = ctx.task_summary,
            file_access_rank = ctx.file_access_rank,
            global_access_counter = ctx.global_access_counter,
            file_states = ctx.file_states,
            search_history = ctx.search_history,
            search_history_order = ctx.search_history_order,
            history = ctx.history,
            thoughts = ctx.thoughts,
            execution_plan = ctx.execution_plan,
            current_task_index = ctx.current_task_index,
            current_turn = ctx.current_turn,
            promoted_files = ctx.promoted_files,
            pinned_files = ctx.pinned_files,
            last_actions = ctx.last_actions,
            handoff_memo = ctx.handoff_memo,
            test_failures = ctx.test_failures,
            turn_requested_files = ctx.turn_requested_files,
            calibration_data = ctx.calibration_data,
            coder_feedback = ctx.coder_feedback,
            task_outcomes = ctx.task_outcomes,
            executed_commands = ctx.executed_commands,
            images_loaded = ctx.images_loaded,
            last_sent_image_hashes = ctx.last_sent_image_hashes,
            consecutive_recoveries = ctx.consecutive_recoveries,
            recent_tool_outputs = ctx.recent_tool_outputs
        })
    end)
    if not ok then
        return nil, "JSON encoding failed: " .. tostring(result)
    end
    return result
end
-- ============================================================================
-- LOAD FROM SNAPSHOT
-- ============================================================================
function M.load_from_snapshot(ctx, json_str)
    local ok, state = pcall(function() return json:decode(json_str) end)
    if not ok or not state then return false, "Corrupted JSON" end
    -- Version check: accept version 1 (legacy/no version), version 2, or nil (legacy)
    local version = state.version
    if version ~= nil and version ~= 1 and version ~= 2 then
        return false, string.format("Unsupported snapshot version: %s", tostring(version))
    end
    -- Structural validation
    local valid, err = M.validate_snapshot(state)
    if not valid then
        return false, "Snapshot validation failed: " .. tostring(err)
    end
    -- Restore knowledge_base as empty; files will be re-read from disk on demand.
    -- state.knowledge_base_paths tells us which files were known previously.
    ctx.knowledge_base = ctx.knowledge_base or {}
    if state.knowledge_base_paths then
        -- Optionally pre-populate file_states for known paths so the system knows they exist
        for _, path in ipairs(state.knowledge_base_paths) do
            if not ctx.file_states[path] then
                ctx.file_states[path] = "KNOWN"
            end
        end
    end
    ctx.task_summary = state.task_summary or ""
    ctx.file_access_rank = state.file_access_rank or {}
    ctx.global_access_counter = state.global_access_counter or 0
    ctx.file_states = state.file_states or {}
    ctx.search_history = state.search_history or {}
    ctx.search_history_order = state.search_history_order or {}
    ctx.history = state.history or {}
    ctx.thoughts = state.thoughts or {}
    ctx.execution_plan = state.execution_plan or {}
    ctx.current_task_index = state.current_task_index or 1
    ctx.current_turn = state.current_turn or 0
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
    ctx.images_loaded = state.images_loaded or false
    ctx.last_sent_image_hashes = state.last_sent_image_hashes or {}
    ctx.consecutive_recoveries = state.consecutive_recoveries or 0
    ctx.recent_tool_outputs = state.recent_tool_outputs or {}
    return true
end
-- ============================================================================
-- RESET
-- ============================================================================
function M.reset(ctx)
    ctx.task_summary = ""
    ctx.history = {}
    ctx.knowledge_base = {}
    ctx.knowledge_base_paths = {}
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