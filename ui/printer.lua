local colors = require('ui.colors')
local M = {}
function M.raw(text)
  io.write(text)
  io.stdout:flush()
end
function M.line(text)
  print(text)
  io.stdout:flush()
end
function M.highlight(text, color)
  color = color or colors.yellow
  print(colors.colorize(text, color))
  io.stdout:flush()
end
function M.banner(text, color)
  color = color or colors.cyan
  print(colors.bold_colorize(text, color))
  io.stdout:flush()
end
function M.divider(char, width)
  char = char or '='
  width = width or 75
  print(colors.dim .. string.rep(char, width) .. colors.reset)
end
function M.fatal_block(fields)
  io.stderr:write('\n' .. colors.red .. '========================================' .. colors.reset .. '\n')
  io.stderr:write(colors.red .. '     [FATAL FAILURE]' .. colors.reset .. '\n')
  io.stderr:write(colors.red .. '========================================' .. colors.reset .. '\n')
  if fields then
    for k, v in pairs(fields) do
      io.stderr:write(string.format('%s  %s: %s%s\n', colors.red, k, v, colors.reset))
    end
  end
  io.stderr:write(colors.red .. '========================================' .. colors.reset .. '\n')
  io.stderr:flush()
end
function M.retry_message(attempt, max_retries, delay)
  print(string.format('\n%s[NETWORK RETRY %d/%d] Retrying in %d seconds...%s',
    colors.yellow, attempt, max_retries, delay, colors.reset))
end
function M.auto_loop_message(count, agent_name)
  print(string.format('\n%s[Auto-loop: %d iterations, Agent: %s]%s',
    colors.dim, count, agent_name, colors.reset))
end
function M.pipe_marker(marker)
  print(marker)
  io.stdout:flush()
end
return M
