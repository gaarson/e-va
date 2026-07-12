-- context_flow.lua
-- Thin facade delegating to submodules.
-- Submodules: config, strategies, history, command_flow, state, feedback,
--             handoff, orchestrator, tokenizer, images, builder.

local M = {}

local utils = require("utils")
local config      = require("context.config")
local strategies  = require("context.strategies")
local history     = require("context.history")
local cmd_flow    = require("context.command_flow")
local state       = require("context.state")
local feedback    = require("context.feedback")
local handoff     = require("context.handoff")
local orchestrator= require("context.orchestrator")
local tokenizer   = require("context.tokenizer")
local images      = require("context.images")
local builder     = require("context.builder")

-- ============================================================================
-- CONSTANTS (re-exported from submodules)
-- ============================================================================
M.DEFAULT_CONFIG      = config.DEFAULT_CONFIG
M.IMPORTANCE_SCORES   = strategies.IMPORTANCE_SCORES
M.MODEL_DIVISORS      = tokenizer.MODEL_DIVISORS
M.PRUNE_STRATEGIES    = strategies.PRUNE_STRATEGIES
M.INJECTION_STRATEGIES= strategies.INJECTION_STRATEGIES

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================
function M.new(flow_config, full_config)
    local self = setmetatable({}, { __index = M })
    self.config = full_config or {}
    self.flow_config = utils.deep_merge(M.DEFAULT_CONFIG, flow_config or {})
    local profile_name = self.config.context_profile
    if profile_name and self.flow_config.model_profiles[profile_name] then
        self.flow_config = utils.deep_merge(self.flow_config, self.flow_config.model_profiles[profile_name])
    end
    -- Internal state
    self.task_summary = ""
    self.history = {}
    self.knowledge_base = {}
    self.file_states = {}
    self.pinned_files = {}
    self.search_history = {}
    self.thoughts = {}
    self.last_actions = {}
    self.turn_requested_files = {}
    self.promoted_files = {}
    self.recent_tool_outputs = {}
    self.global_access_counter = 0
    self.file_access_rank = {}
    self.execution_plan = {}
    self.current_task_index = 1
    self.handoff_memo = nil
    self.images = {}
    self.images_loaded = false
    self.last_sent_image_hashes = {}
    self.test_failures = 0
    self.consecutive_recoveries = 0
    self.file_tree = nil
    self.current_turn = 0
    self.calibration_data = {}
    self.coder_feedback = {
        tasks_completed = {},
        tasks_failed = {},
        errors_encountered = {},
        plan_deviations = {},
        recommendations = {}
    }
    self.task_outcomes = {}
    self.executed_commands = {}
    return self
end

-- ============================================================================
-- HISTORY / KNOWLEDGE BASE (delegates to context.history)
-- ============================================================================
function M:add_message(agent_name, role, content)
    return history.add_message(self, agent_name, role, content)
end
function M:get_history(agent_name)
    return history.get_history(self, agent_name)
end
function M:prune_history(agent_name)
    return history.prune_history(self, agent_name)
end
function M:compress_history(agent_name)
    return history.compress_history(self, agent_name)
end
function M:squash_last_mutation(agent_name)
    return history.squash_last_mutation(self, agent_name)
end
function M:add_file(path, content)
    return history.add_file(self, path, content)
end
function M:pin_file(path)
    return history.pin_file(self, path)
end
function M:unpin_file(path)
    return history.unpin_file(self, path)
end
function M:add_tool_output(tool_name, output)
    return history.add_tool_output(self, tool_name, output)
end
function M:track_requested_file(path)
    return history.track_requested_file(self, path)
end
function M:clear_turn_requested_files()
    return history.clear_turn_requested_files(self)
end
function M:is_duplicate_command(cmd)
    return history.is_duplicate_command(self, cmd)
end
function M:add_executed_command(cmd)
    return history.add_executed_command(self, cmd)
end
function M:should_squash(agent_name)
    return history.should_squash(self, agent_name)
end
function M:drop_last_message(agent_name)
    return history.drop_last_message(self, agent_name)
end
function M:replace_last_assistant_message(agent_name, new_content)
    return history.replace_last_assistant_message(self, agent_name, new_content)
end
function M:add_thought(turn, thought_text)
    return history.add_thought(self, turn, thought_text)
end
function M:get_thoughts_digest()
    return history.get_thoughts_digest(self)
end
function M:touch_file(path)
    return history.touch_file(self, path)
end
function M:has_searched(query)
    return history.has_searched(self, query)
end
function M:add_search_result(query, result)
    return history.add_search_result(self, query, result)
end

-- ============================================================================
-- CONTEXT BUILDING (delegates to context.builder)
-- ============================================================================
function M:build_context(agent_name, agent_cfg, available_tokens)
    return builder.build_context(self, agent_name, agent_cfg, available_tokens)
end
function M:get_recency_block()
    return builder.get_recency_block(self)
end
function M:get_search_digest(max_tokens)
    return builder.get_search_digest(self, max_tokens)
end
function M:get_system_prompt(agent_cfg)
    return builder.get_system_prompt(self, agent_cfg)
end
function M:get_engine_directives(agent_cfg)
    return builder.get_engine_directives(self, agent_cfg)
end
function M:load_prompt(path)
    return builder.load_prompt(self, path)
end
function M:get_plan_text()
    return builder.get_plan_text(self)
end
function M:get_actions_text()
    return builder.get_actions_text(self)
end
function M:get_file_context(file_info)
    return builder.get_file_context(self, file_info)
end
function M:get_memory_block(max_tokens)
    return builder.get_memory_block(self, max_tokens)
end
function M:get_report(agent_name)
    return builder.get_report(self, agent_name)
end
function M:build_system_state_xml()
    return builder.build_system_state_xml(self)
end
function M:get_recency_tool_outputs()
    return builder.get_recency_tool_outputs(self)
end
function M:get_image_content_parts()
    return builder.get_image_content_parts(self)
end
function M:get_changes_summary()
    return builder.get_changes_summary(self)
end
function M:get_insights_summary()
    return builder.get_insights_summary(self)
end
function M:get_recent_thoughts_text()
    return builder.get_recent_thoughts_text(self)
end

-- ============================================================================
-- COMMAND FLOW (delegates to context.command_flow)
-- ============================================================================
function M:process_turn_response(agent_name, raw_content, executor)
    return cmd_flow.process_turn_response(self, agent_name, raw_content, executor)
end

-- ============================================================================
-- STATE (delegates to context.state)
-- ============================================================================
function M:snapshot()
    return state.snapshot(self)
end
function M:load_from_snapshot(json_str)
    return state.load_from_snapshot(self, json_str)
end
function M:reset()
    return state.reset(self)
end
function M:update_summary(new_summary)
    return state.update_summary(self, new_summary)
end
function M:add_action(action_type, summary)
    return state.add_action(self, action_type, summary)
end

-- ============================================================================
-- FEEDBACK (delegates to context.feedback)
-- ============================================================================
function M:record_task_success(task_index, summary)
    return feedback.record_task_success(self, task_index, summary)
end
function M:record_task_failure(task_index, error_msg)
    return feedback.record_task_failure(self, task_index, error_msg)
end
function M:record_error(error_msg)
    return feedback.record_error(self, error_msg)
end
function M:record_deviation(note)
    return feedback.record_deviation(self, note)
end
function M:add_recommendation(rec)
    return feedback.add_recommendation(self, rec)
end
function M:generate_feedback_report()
    return feedback.generate_feedback_report(self)
end
function M:inject_feedback_as_message(agent_name, feedback_text)
    return feedback.inject_feedback_as_message(self, agent_name, feedback_text)
end

-- ============================================================================
-- HANDOFF (delegates to context.handoff)
-- ============================================================================
function M:generate_handoff_memo(agent_name, agent_cfg)
    return handoff.generate_handoff_memo(self, agent_name, agent_cfg)
end
function M:inject_handoff_files(agent_name)
    return handoff.inject_handoff_files(self, agent_name)
end
function M:set_handoff_memo(memo)
    return handoff.set_handoff_memo(self, memo)
end
function M:get_handoff_files()
    return handoff.get_handoff_files(self)
end
function M:clear_history_for_stage(strategy)
    return handoff.clear_history_for_stage(self, strategy)
end
function M:sync_files()
    return handoff.sync_files(self)
end

-- ============================================================================
-- ORCHESTRATOR (delegates to context.orchestrator)
-- ============================================================================
function M:optimize_context(instructions)
    return orchestrator.optimize_context(self, instructions)
end

-- ============================================================================
-- TOKENIZER (delegates to context.tokenizer)
-- ============================================================================
function M:estimate_tokens(text, agent_cfg)
    return tokenizer.estimate_tokens(self, text, agent_cfg)
end
function M:calibrate_from_actual(agent_name, estimated_tokens, actual_tokens)
    return tokenizer.calibrate_from_actual(self, agent_name, estimated_tokens, actual_tokens)
end
function M:get_calibration_stats()
    return tokenizer.get_calibration_stats(self)
end

-- ============================================================================
-- IMAGES (delegates to context.images)
-- ============================================================================
function M:load_images(dir_path)
    return images.load_images(self, dir_path)
end
function M:add_image(base64_data, mime_type)
    return images.add_image(self, base64_data, mime_type)
end
function M:purge_images()
    return images.purge_images(self)
end

-- ============================================================================
-- ALIASES (backward compatibility)
-- ============================================================================
function M:get_execution_plan_text() return self:get_plan_text() end
function M:get_last_actions_text() return self:get_actions_text() end

return M

