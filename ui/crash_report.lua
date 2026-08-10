local colors = require('ui.colors')
local M = {}
--- Prints a standardized crash report to stderr.
-- Replaces the inline io.stderr:write block in agent/init.lua.
-- @param code The exit code (number or string)
-- @param status Optional status table from status_server ({agent_name, current_turn, current_stage, state})
function M.print_crash_report(code, status)
    io.stderr:write('\n' .. colors.red .. '========================================' .. colors.reset .. '\n')
    io.stderr:write(colors.red .. '     [CRASH REPORT]' .. colors.reset .. '\n')
    io.stderr:write(colors.red .. '========================================' .. colors.reset .. '\n')
    io.stderr:write(string.format('%s  Exit Code: %s%s\n',
        colors.red, tostring(code or 'nil'), colors.reset))
    -- Environment variables
    io.stderr:write(string.format('%s  AGENT_HOME: %s%s\n',
        colors.red, os.getenv('AGENT_HOME') or 'UNSET', colors.reset))
    io.stderr:write(string.format('%s  PROJECT_ROOT: %s%s\n',
        colors.red, os.getenv('PROJECT_ROOT') or 'UNSET', colors.reset))
    io.stderr:write(string.format('%s  LLM_BASE_URL: %s%s\n',
        colors.red, os.getenv('LLM_BASE_URL') or 'UNSET', colors.reset))
    io.stderr:write(string.format('%s  LLM_MODEL: %s%s\n',
        colors.red, os.getenv('LLM_MODEL') or 'UNSET', colors.reset))
    -- Status info if provided
    if status then
        io.stderr:write(string.format('%s  Last Agent: %s%s\n',
            colors.red, tostring(status.agent_name or 'unknown'), colors.reset))
        io.stderr:write(string.format('%s  Last Turn: %s%s\n',
            colors.red, tostring(status.current_turn or 0), colors.reset))
        io.stderr:write(string.format('%s  Last Stage: %s%s\n',
            colors.red, tostring(status.current_stage or 'unknown'), colors.reset))
        io.stderr:write(string.format('%s  Last State: %s%s\n',
            colors.red, tostring(status.state or 'unknown'), colors.reset))
    end
    io.stderr:write(colors.red .. '========================================' .. colors.reset .. '\n')
    io.stderr:flush()
end
--- Prints a signal received message.
-- Used for SIGTERM/SIGINT handling.
-- @param sig_name The signal name (e.g., "SIGTERM", "SIGINT")
function M.print_signal_received(sig_name)
    print('\n' .. colors.yellow .. string.format('[SIGNAL] Received %s. Shutting down gracefully...', sig_name) .. colors.reset)
end
return M