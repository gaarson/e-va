local colors = require('ui.colors')
local strings = require('utils.strings')
local M = {}
M.COMMANDS = {
  ['/go'] = 'NEXT_STAGE',
  ['/back'] = 'PREV_STAGE',
  ['/exit'] = 'ABORT',
  ['/status'] = 'STATUS',
  ['/help'] = 'HELP',
  ['/messages'] = 'MESSAGES',
}
M.HELP_TEXT = [[
Available commands:
  /go       - Move to the next pipeline stage
  /back     - Move back to the previous stage
  /exit     - Abort execution
  /mode <s> - Switch to stage <s>
  /status   - Show current status
  /messages - Dump current LLM request messages to console
  /help     - Show this help message
]]
function M.parse(input, config)
  if not input then
    return { action = 'ABORT', message = 'User aborted the execution.' }
  end
  local trimmed = strings.trim(input)
  if trimmed == '' then
    return { action = 'SKIP', message = 'Empty input.' }
  end
  -- Extract first line for command matching (handles multiline input like "/go\n/go")
  local first_line = strings.trim(trimmed:match("^[^\r\n]*"))
  -- Check for exact command matches first
  if M.COMMANDS[first_line] then
    local action = M.COMMANDS[first_line]
    if action == 'NEXT_STAGE' then
      return { action = 'NEXT_STAGE', message = 'Moving to the next pipeline stage...' }
    elseif action == 'PREV_STAGE' then
      return { action = 'PREV_STAGE', message = 'Moving back to previous stage...' }
    elseif action == 'ABORT' then
      return { action = 'ABORT', message = 'User aborted the execution.' }
    elseif action == 'STATUS' then
      return { action = 'STATUS', message = 'Requesting status update.' }
    elseif action == 'HELP' then
      return { action = 'HELP', message = M.HELP_TEXT }
    elseif action == 'MESSAGES' then
      return { action = 'MESSAGES', message = 'Dumping current messages...' }
    end
  end
  -- Check for /mode <stage_name>
  local mode_match = first_line:match('^/mode%s+(.+)$')
  if mode_match then
    local mode_name = strings.trim(mode_match)
    if config and config.PIPELINE then
      for i, s in ipairs(config.PIPELINE) do
        if s.stage == mode_name then
          return { action = 'SWITCH_STAGE', target_idx = i, message = 'Switching to stage: ' .. mode_name }
        end
      end
    end
    return { action = 'ERROR', message = 'Stage \'' .. mode_name .. '\' not found in pipeline.' }
  end
  -- Default: treat as a message (use full trimmed input for multiline support)
  return { action = 'MESSAGE', message = trimmed }
end
return M