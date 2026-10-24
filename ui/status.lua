local status_server = require('status_server')
local colors = require('ui.colors')
local M = {}
function M.init(port)
  return status_server.start(port)
end
function M.poll()
  status_server.poll()
end
function M.stop()
  status_server.stop()
end
function M.update(fields)
  status_server.update_status(fields)
end
function M.log(line)
  status_server.add_log(line)
end
function M.is_cancel_requested()
  return status_server.is_cancel_requested()
end
function M.check_cancel()
  if M.is_cancel_requested() then
    print('\n' .. colors.red .. '[SYSTEM] Cancellation requested via status server.' .. colors.reset)
    return true
  end
  return false
end
return M
