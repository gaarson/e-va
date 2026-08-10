local colors = require('ui.colors')
local tty = require('ui.tty')
local M = {}
local _is_tty = tty.is_tty
-- Spinner state
M._spinner_thread = nil
M._spinner_running = false
-- Characters for spinner
local SPINNER_CHARS = {'-', '\\', '|', '/' }
local SPINNER_SPEED = 0.1
-- Spinner state
M._spinner_idx = 1
--- Starts a terminal spinner (TTY only)
-- @param label string: Label to display next to spinner
function M.spinner_start(label)
    if not _is_tty then
        return
    end
    if M._spinner_running then
        M.spinner_stop()
    end
    M._spinner_running = true
    M._spinner_label = label or 'Working...'
    M._spinner_idx = 1
    io.write(string.format('\r%s %s...', SPINNER_CHARS[M._spinner_idx], M._spinner_label))
    io.stdout:flush()
end
--- Advances the spinner frame (caller-driven animation)
function M.spinner_tick()
    if not M._spinner_running or not _is_tty then
        return
    end
    M._spinner_idx = (M._spinner_idx % #SPINNER_CHARS) + 1
    io.write(string.format('\r%s %s...', SPINNER_CHARS[M._spinner_idx], M._spinner_label or 'Working...'))
    io.stdout:flush()
end

--- Stops the spinner and clears the line
function M.spinner_stop()
    M._spinner_running = false
    if not _is_tty then
        return
    end
    -- Clear the line and move to next line
    io.write('\r' .. string.rep(' ', 70) .. '\r')
    io.stdout:flush()
end

--- Prints a text progress bar (TTY-aware)
-- @param current number: Current progress value
-- @param total number: Total value
-- @param label string: Optional label
function M.progress_bar(current, total, label)
    if not _is_tty then
        -- In non-TTY, just print a simple text update
        print(string.format('[PROGRESS] %s: %d/%d (%.1f%%)',
            label or 'Progress', current, total, (current / total) * 100))
        return
    end

    local width = 40
    local pct = math.min(current / total, 1.0)
    local filled = math.floor(pct * width)
    local empty = width - filled

    local bar = string.rep('=', filled) .. string.rep(' ', empty)
    local msg = string.format('\r[%s] %s %.0f%%', bar, label or '', pct * 100)

    io.write(colors.cyan .. msg .. colors.reset)
    io.stdout:flush()

    if pct >= 1.0 then
        io.write('\n')
        io.stdout:flush()
    end
end

--- Prints a formatted header for batch tasks
-- @param idx number: Current task index
-- @param total number: Total number of tasks
-- @param task_name string: Name or description of the task
function M.batch_task_header(idx, total, task_name)
    local header = string.format('=== TASK [%d/%d]: %s ===', idx, total, task_name or 'Unnamed')
    print(colors.bold .. colors.magenta .. header .. colors.reset)
    io.stdout:flush()
end

return M