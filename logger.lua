local M = {}
local io = require("io")
local os = require("os")

local agent_home = os.getenv("AGENT_HOME") or "."
local project_root = os.getenv("PROJECT_ROOT") or "."

local project_name = project_root:match("([^/]+)$") or "default_project"

local log_dir = string.format("%s/logs/%s", agent_home, project_name)

os.execute(string.format("mkdir -p '%s'", log_dir))

-- Module-level state
local indent_level = 0
local logging_enabled = true
local log_file = nil
-- Request ID tracing: simple incrementing counter for correlating LLM requests
local _req_id_counter = 0
local function _generate_req_id()
    _req_id_counter = _req_id_counter + 1
    -- Wrap at 4 billion to avoid overflow issues, format as 8-char hex
    if _req_id_counter > 0xFFFFFFFF then _req_id_counter = 1 end
    return string.format("%08x", _req_id_counter)
end
-- Per-turn request ID storage: maps agent_name -> current req_id
local _current_req_ids = {}
function M.new_request_id(agent_name)
    local rid = _generate_req_id()
    _current_req_ids[agent_name or "default"] = rid
    return rid
end
function M.get_request_id(agent_name)
    return _current_req_ids[agent_name or "default"] or nil
end
function M.clear_request_id(agent_name)
    _current_req_ids[agent_name or "default"] = nil
end

-- Timestamp helper
local function get_timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- Initialize persistent log file at module load
local function init_log_file()
    if log_file then return end
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local filename = string.format("%s/run_%s.log", log_dir, timestamp)
    local f, err = io.open(filename, "a")
    if f then
        log_file = f
        local ts = get_timestamp()
        log_file:write(string.format("[%s] [INIT] Logger started (file: %s)\n", ts, filename))
        log_file:flush()

        -- Crash-safe shutdown via __gc on a dummy object
        local shutdown_guard = setmetatable({}, {
            __gc = function()
                if log_file then
                    M.close()
                end
            end
        })
        -- Keep reference alive at module level so GC doesn't collect prematurely during normal operation
        -- We intentionally let this be collected only on Lua shutdown
        rawset(M, "_shutdown_guard", shutdown_guard)
    else
        io.stderr:write(string.format("[LOGGER FATAL] Failed to open log file: %s (%s)\n", filename, tostring(err)))
    end
end

init_log_file()

-- Write a line to the persistent log file (respects logging_enabled and indent)
local function write_to_file(level, msg)
    if not logging_enabled or not log_file then return end
    local ts = get_timestamp()
    local indent_str = string.rep("  ", indent_level)
    log_file:write(string.format("[%s] %s[%s] %s\n", ts, indent_str, level, msg))
    log_file:flush()
end

-- Inspect helper (preserved from original)
local function inspect_impl(root, options)
    options = options or {}
    local depth = options.depth or 3
    local cache = { [root] = "." }
    local function _dump(t, space, name, level)
        if level > depth then return space .. tostring(t) .. "..." end
        local temp = {}
        for k,v in pairs(t) do
            local key = tostring(k)
            if type(k) == "string" then key = '"' .. key .. '"' end
            if cache[v] then
                table.insert(temp, "+" .. key .. " {" .. cache[v] .. "}")
            elseif type(v) == "table" then
                local new_key = name .. "." .. key
                cache[v] = new_key
                table.insert(temp, "+" .. key .. _dump(v, space .. (next(t,k) and "|" or " " ) .. string.rep(" ", #key), new_key, level + 1))
            else
                local val_str = tostring(v)
                if type(v) == "string" then val_str = '"' .. val_str .. '"' end
                table.insert(temp, "+" .. key .. " [" .. val_str .. "]")
            end
        end
        return table.concat(temp, "\n" .. space)
    end
    if type(root) ~= "table" then return tostring(root) end
    return "\n" .. _dump(root, "  ", "", 1)
end

-- Core logging functions (backward compatible signatures)

function M.info(msg, data)
    local d_str = data and inspect_impl(data) or ""
    local full_msg = msg .. d_str

    -- Console output (unchanged format)
    print(string.format("\27[32m[INFO]\27[0m %s", full_msg))

    -- File output (with timestamp and indent)
    write_to_file("INFO", full_msg)
end

function M.warn(msg, data)
    local d_str = data and inspect_impl(data) or ""
    local full_msg = msg .. d_str

    -- Console output (unchanged format)
    print(string.format("\27[33m[WARN]\27[0m %s", full_msg))

    -- File output (with timestamp and indent)
    write_to_file("WARN", full_msg)
end

function M.error(msg, data)
    local d_str = data and inspect_impl(data) or ""
    local full_msg = msg .. d_str

    -- Console output (unchanged format)
    io.stderr:write(string.format("\27[31m[ERROR]\27[0m %s\n", full_msg))

    -- File output (with timestamp and indent)
    write_to_file("ERROR", full_msg)
end

-- Indentation support

function M.push_indent()
    indent_level = indent_level + 1
end

function M.pop_indent()
    if indent_level > 0 then
        indent_level = indent_level - 1
    end
end

-- Toggleable logging

function M.enable()
    logging_enabled = true
end

function M.disable()
    logging_enabled = false
end

-- Flush: force write buffer and write a marker

function M.flush()
    if log_file then
        local ts = get_timestamp()
        log_file:write(string.format("[%s] [FLUSH] Logger flushed\n", ts))
        log_file:flush()
    end
end

-- Close: write final marker, flush, close handle

function M.close()
    if log_file then
        local ts = get_timestamp()
        log_file:write(string.format("[%s] [SHUTDOWN] Logger closed\n", ts))
        log_file:flush()
        log_file:close()
        log_file = nil

        -- Remove shutdown guard so __gc doesn't try to close again on Lua exit after explicit close() call.
        -- However if close() was called explicitly we don't want __gc to do anything harmful.
        -- Setting _shutdown_guard to nil allows it to be GC'd harmlessly since __gc checks log_file which is nil.
        rawset(M, "_shutdown_guard", nil)
    end
end

-- Context logging (FIXED: append mode instead of overwrite)

function M.log_context(turn, phase, content)
    local filename = string.format("%s/turn_%03d_%s.log", log_dir, turn, phase)
    local f = io.open(filename, "a")
    if f then
        f:write(content)
        f:close()
    else
        io.stderr:write(string.format("[LOGGER FATAL] Failed to write log to: %s\n", filename))
    end
end

-- Pretty message logging (unchanged signature and behavior)

function M.log_messages_pretty(messages, turn, agent_name, ctx)
    local colors = {
        system    = "\27[35m",  -- magenta
        user      = "\27[32m",  -- green
        assistant = "\27[36m",  -- cyan
        end_c     = "\27[0m"
    }

    print("\n")
    print(string.format("\27[1m[MESSAGES] Turn %d | Agent: %s | Total: %d msg(s)\27[0m", turn, agent_name, #messages))

    for i, msg in ipairs(messages) do
        local role = msg.role or "unknown"
        local color = colors[role] or "\27[37m"

        local content = msg.content
        if type(content) == "table" then
            local json = require("JSON")
            content = json:encode(content, 2)
        end
        content = tostring(content)

        print(string.format(
            "\27[1m[%d]\27[0m \27[1m%s\27[0m \27[90m(%d tokens)",
            i, color .. role, ctx:estimate_tokens(content)))

        io.write(string.format("%s%s\27[0m\n", color, content))
        io.flush()
    end

    print("\n")
end

function M.log_final_dump(ctx, turn, agent_name, agent_cfg)
    local messages = {}
    -- Get system prompt
    if agent_cfg and ctx.get_system_prompt then
        local ok, prompt_val = pcall(ctx.get_system_prompt, ctx, agent_cfg)
        if ok and prompt_val and prompt_val ~= "" then
            table.insert(messages, { role = "system", content = prompt_val })
        end
    end
    -- Get full history for the agent
    if ctx.get_history then
        local ok, history_val = pcall(ctx.get_history, ctx, agent_name)
        if ok and history_val then
            for _, msg in ipairs(history_val) do
                table.insert(messages, msg)
            end
        end
    end
    if #messages > 0 then
        M.log_messages_pretty(messages, turn, agent_name, ctx)
    else
        print("\n\27[33m[LOGGER] No messages to dump for agent: " .. tostring(agent_name) .. "\27[0m\n")
    end
end

return M