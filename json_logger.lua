local json = require("JSON")
local io = require("io")
local os = require("os")
local M = {}
-- Internal state
local _agent_name = "unknown"
local _turn = 0
local _stage = "unknown"
local _buffer = {}
local _max_buffer_lines = 10
local _log_file = nil
local _fd3 = nil
local _stderr_fallback = true
-- ISO 8601 timestamp
local function iso_timestamp()
    return os.date("%Y-%m-%dT%H:%M:%SZ")
end
-- Open structured log file
local function open_log_file()
    if _log_file then return end
    local project_root = os.getenv("PROJECT_ROOT") or "."
    local log_dir = project_root .. "/.e-va-conf"
    os.execute(string.format("mkdir -p '%s'", log_dir))
    local path = log_dir .. "/structured.log"
    local f, err = io.open(path, "a")
    if f then
        _log_file = f
    else
        io.stderr:write(string.format("[JSON_LOGGER] Failed to open log file: %s (%s)\n", path, tostring(err)))
    end
end
-- Open fd 3 if available
local function open_fd3()
    if _fd3 then return end
    -- Try to open /proc/self/fd/3 — if the host has redirected fd 3, this works
    local f, err = io.open("/proc/self/fd/3", "w")
    if f then
        _fd3 = f
        _stderr_fallback = false
    end
    -- Fallback: just use stderr
    if not _fd3 then
        _fd3 = io.stderr
    end
end
-- Flush buffer to outputs
function M.flush()
    if #_buffer == 0 then return end
    local lines = table.concat(_buffer, "\n") .. "\n"
    if _log_file then
        pcall(function() _log_file:write(lines) _log_file:flush() end)
    end
    if _fd3 then
        pcall(function() _fd3:write(lines) _fd3:flush() end)
    end
    _buffer = {}
end
-- Write a single JSON log entry
local function write_entry(level, msg)
    local entry = {
        ts = iso_timestamp(),
        level = level,
        agent = _agent_name,
        turn = _turn,
        stage = _stage,
        msg = tostring(msg or "")
    }
    local ok, encoded = pcall(json.encode, json, entry)
    local line = ok and encoded or string.format('{"ts":"%s","level":"%s","agent":"%s","turn":%d,"stage":"%s","msg":"%s"}',
        entry.ts, entry.level, entry.agent, entry.turn, entry.stage, tostring(msg or ""))
    table.insert(_buffer, line)
    -- Flush if buffer reaches threshold
    if #_buffer >= _max_buffer_lines then
        M.flush()
    end
end
function M.init(agent_name, turn, stage)
    _agent_name = agent_name or "unknown"
    _turn = turn or 0
    _stage = stage or "unknown"
    open_log_file()
    open_fd3()
end
function M.set_context(agent_name, turn, stage)
    if agent_name then _agent_name = agent_name end
    if turn then _turn = turn end
    if stage then _stage = stage end
end
function M.info(msg)
    write_entry("INFO", msg)
end
function M.warn(msg)
    write_entry("WARN", msg)
end
function M.error(msg)
    write_entry("ERROR", msg)
end
-- GC hook to flush on shutdown
setmetatable(M, {
    __gc = function()
        M.flush()
        if _log_file then
            pcall(function() _log_file:close() end)
        end
    end
})
return M