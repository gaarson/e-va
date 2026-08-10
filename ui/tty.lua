local M = {}

--- Detects whether stdout is connected to a TTY.
-- Uses multiple fallback strategies for maximum compatibility across Lua versions and environments.
-- @return boolean: true if running in a TTY, false otherwise
function M.detect()
    -- Primary: io.stdout:isatty() (available in LuaJIT and Lua 5.2+)
    if io.stdout and type(io.stdout.isatty) == 'function' then
        return io.stdout:isatty()
    end

    -- Fallback 1: Check TERM environment variable
    local term = os.getenv('TERM')
    if term and term ~= '' and term ~= 'dumb' then
        return true
    end

    -- Fallback 2: Shell test (POSIX)
    local ok, result = pcall(function()
        return os.execute('test -t 1 >/dev/null 2>&1 && echo 1 || echo 0')
    end)
    if ok and result == 0 then
        return true
    end

    return false
end

--- Cached TTY detection result.
-- Evaluated once at module load time. Can be overridden by TTY environment variable.
M.is_tty = M.detect()

--- Allow overriding TTY detection via environment variable.
-- Useful for CI/CD pipelines or forced TTY simulation.
if not M.is_tty then
    local tty_env = os.getenv('TTY')
    M.is_tty = (tty_env == '1' or tty_env == 'true')
end

return M
