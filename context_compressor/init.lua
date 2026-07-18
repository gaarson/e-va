
local M = {}


-- Load sub-modules

local helpers = require("context_compressor.helpers")

local thinking = require("context_compressor.thinking")

local tool_output = require("context_compressor.tool_output")

local history = require("context_compressor.history")


-- Re-export helpers

M.DEFAULT_CONFIG = helpers.DEFAULT_CONFIG

M._is_task_critical = helpers._is_task_critical

M._summarize_message = helpers._summarize_message

M._truncate_middle = helpers._truncate_middle


-- Re-export thinking

M.compress_assistant_thinking = thinking.compress_assistant_thinking


-- Re-export tool_output

M.classify_tool_output = tool_output.classify_tool_output

M.compress_tool_output = tool_output.compress_tool_output

M._compress_shell_output = tool_output._compress_shell_output

M._compress_search_output = tool_output._compress_search_output

M._compress_generic_output = tool_output._compress_generic_output


-- Re-export history

M.compress_history_window = history.compress_history_window

M.calculate_compression_ratio = history.calculate_compression_ratio

M.is_compressible = history.is_compressible

M.compress_message = history.compress_message


return M

