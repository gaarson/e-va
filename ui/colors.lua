local M = {}
M.reset = '\27[0m'
M.bold = '\27[1m'
M.dim = '\27[90m'
M.red = '\27[31m'
M.green = '\27[32m'
M.yellow = '\27[33m'
M.blue = '\27[34m'
M.magenta = '\27[35m'
M.cyan = '\27[36m'
M.white = '\27[37m'
M.gray = '\27[90m'
M.bg_red = '\27[41m'
M.bg_yellow = '\27[43m'
function M.colorize(text, color)
  return color .. text .. M.reset
end
function M.bold_colorize(text, color)
  return M.bold .. color .. text .. M.reset
end
return M
