local colors = require('ui.colors')
local strings = require('utils.strings')
local socket = require('socket')
local input = require('ui.input')
local M = {}
M.MAX_INTERRUPTION_RETRIES = 3
--- Sanitize user input: strip control characters except \n and \t, remove null bytes,
--- keep printable ASCII and valid UTF-8 continuation bytes.
-- Removes bytes 0x00-0x08, 0x0B-0x0C, 0x0E-0x1F.
-- Keeps \n (0x0A), \t (0x09), and bytes >= 0x20 plus UTF-8 continuation bytes (0x80-0xFF).
function M.sanitize_input(str)
  if not str or type(str) ~= 'string' then return '' end
  local out = {}
  for i = 1, #str do
    local byte = str:byte(i)
    -- Keep: \t (0x09), \n (0x0A), printable ASCII (0x20-0x7E), UTF-8 bytes (0x80-0xFF)
    -- Remove: 0x00-0x08, 0x0B-0x0C, 0x0E-0x1F
    if byte == 0x09 or byte == 0x0A or (byte >= 0x20) then
      table.insert(out, str:sub(i, i))
    end
  end
  return table.concat(out)
end
--- Restore terminal to sane (cooked) mode. The 200ms sleep in callers is sufficient
--- for the terminal to stabilize after ESC monitor teardown.
local function flush_terminal_buffer()
  os.execute('stty sane 2>/dev/null')
end
function M.should_abort(interruption_count)
  return interruption_count >= M.MAX_INTERRUPTION_RETRIES
end
--- Handle interruption and capture user input, returning the sanitized string or nil.
-- Does NOT modify any messages table. Caller is responsible for storing in history.
-- @param agent_name string (unused, kept for API consistency)
-- @return string|nil sanitized user input if non-empty, nil otherwise
function M.handle_interruption_with_capture(agent_name)
  -- (1) Delay 300ms to let terminal state stabilize after ESC monitor teardown
  socket.sleep(0.3)
  -- (2) Restore terminal to cooked mode BEFORE flushing
  os.execute('stty sane 2>/dev/null')
  -- (3) Drain stale bytes from terminal input buffer (ESC key, simultaneous keystrokes)
  flush_terminal_buffer()
  os.execute('dd if=/dev/tty bs=256 count=1 2>/dev/null > /dev/null')
  print('\n' .. colors.yellow .. '[SYSTEM] Generation interrupted. Provide additional context or corrections (or press Ctrl+D to continue):' .. colors.reset)
  local user_input = input.read_text('[CORRECTION] ', nil)
  -- (4) Sanitize user_input
  if user_input then
    user_input = M.sanitize_input(user_input)
  end
  if user_input and strings.trim(user_input) ~= '' then
    return user_input
  end
  return nil
end
return M