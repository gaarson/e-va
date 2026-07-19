
local M = {}


-- Load sub-modules
local states = require("multi_stage_executor.states")
local prompts = require("multi_stage_executor.prompts")
local parsers = require("multi_stage_executor.parsers")
local executor = require("multi_stage_executor.executor")

-- Re-export states
M.STATES = states.STATES
M.TOOL_GENERATE_HINTS = states.TOOL_GENERATE_HINTS
M.TOOL_REVIEW_CHECKS = states.TOOL_REVIEW_CHECKS

-- Re-export prompts
M.DEFAULT_INTENT_PROMPT = prompts.DEFAULT_INTENT_PROMPT
M.DEFAULT_GENERATE_PROMPT = prompts.DEFAULT_GENERATE_PROMPT
M.DEFAULT_REVIEW_PROMPT = prompts.DEFAULT_REVIEW_PROMPT

-- Re-export executor
M.new = executor.new

return M

