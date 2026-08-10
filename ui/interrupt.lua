local colors = require('ui.colors')
local strings = require('utils.strings')
local M = {}
M.MAX_INTERRUPTION_RETRIES = 3
function M.handle_interruption(messages, agent_name)
  print('\n' .. colors.yellow .. '[SYSTEM] Generation interrupted. Provide additional context or corrections (or press Enter to continue):' .. colors.reset)
  local user_input = io.read('*l')
  if user_input and strings.trim(user_input) ~= '' then
    table.insert(messages, { role = 'user', content = user_input })
    return true -- user provided context, retry
  end
  return true -- just continue
end
function M.should_abort(interruption_count)
  return interruption_count >= M.MAX_INTERRUPTION_RETRIES
end
return M
