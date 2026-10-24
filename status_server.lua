local socket = require("socket")
local M = {}
-- Internal state
M._running = false
M._server = nil
M._port = 8080
M._cancel_requested = false
M._status = {
    agent_name = "unknown",
    current_turn = 0,
    current_stage = "",
    stage_index = 0,
    total_stages = 0,
    tokens_used = 0,
    state = "idle",
    uptime_seconds = 0
}
M._start_time = 0
M._log_buffer = {}
M._MAX_LOG_ENTRIES = 1000
-- Simple lock (Lua is single-threaded, but protects against coroutine interleaving)
local _lock = false
local function _acquire_lock()
    _lock = true
end
local function _release_lock()
    _lock = false
end
--- Ring buffer for logs
local function _add_log_internal(line)
    table.insert(M._log_buffer, line)
    if #M._log_buffer > M._MAX_LOG_ENTRIES then
        table.remove(M._log_buffer, 1)
    end
end
--- Parse HTTP request (minimal parser)
local function _parse_request(raw)
    if not raw or #raw == 0 then return nil, nil, nil end
    local first_line = raw:match("^(%-.-)\r?\n")
    if not first_line then return nil, nil, nil end
    local method, path = first_line:match("^(%S+)%s+(%S+)")
    if not method or not path then return nil, nil, nil end
    -- Parse query string
    local query = {}
    local qstr = path:match("\\?(.+)$")
    if qstr then
        path = path:match("^(.-)\\?.*$") or path
        for k, v in qstr:gmatch("(%w+)=(%w+)") do
            query[k] = v
        end
    end
    -- Read headers until empty line
    local headers = {}
    for header in raw:gmatch("[^\r\n]+") do
        if header == "" then break end
        local key, val = header:match("^(%S-):%s*(.+)$")
        if key then headers[key:lower()] = val end
    end
    return method, path, query, headers
end
--- Build JSON response
local cjson
pcall(function() cjson = require("cjson") end)
local function _json_encode(tbl)
    if cjson then
        return cjson.encode(tbl)
    end
    -- Fallback manual JSON encoder
    local function _enc(t)
        if type(t) == "table" then
            local parts = {}
            local is_array = false
            if #t > 0 then is_array = true end
            if is_array then
                for _, v in ipairs(t) do
                    table.insert(parts, '"' .. tostring(v) .. '"')
                end
                return "[" .. table.concat(parts, ",") .. "]"
            else
                local parts = {}
                for k, v in pairs(t) do
                    table.insert(parts, '"' .. tostring(k) .. '":"' .. tostring(v) .. '"')
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
        end
        return '"' .. tostring(t) .. '"'
    end
    return _enc(tbl)
end
--- Build HTTP response
local function _http_response(status_code, status_text, body, content_type)
    content_type = content_type or "application/json"
    local length = #body
    return string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
        status_code, status_text, content_type, length, body
    )
end
--- Handle incoming request
local function _handle_request(method, path, query)
    if method == "GET" and path == "/health" then
        return _http_response(200, "OK", _json_encode({ status = "ok" }))
    end
    if method == "GET" and path == "/status" then
        _acquire_lock()
        local snapshot = {}
        for k, v in pairs(M._status) do snapshot[k] = v end
        snapshot.uptime_seconds = socket.gettime() - M._start_time
        _release_lock()
        return _http_response(200, "OK", _json_encode(snapshot))
    end
    if method == "POST" and path == "/cancel" then
        M._cancel_requested = true
        return _http_response(200, "OK", _json_encode({ status = "cancel_requested" }))
    end
    if method == "GET" and path == "/logs" then
        local n = tonumber(query.n) or 50
        _acquire_lock()
        local logs = {}
        local start_idx = math.max(1, #M._log_buffer - n + 1)
        for i = start_idx, #M._log_buffer do
            table.insert(logs, M._log_buffer[i])
        end
        _release_lock()
        return _http_response(200, "OK", _json_encode({ logs = logs, count = #logs }))
    end
    return _http_response(404, "Not Found", _json_encode({ error = "not_found" }))
end
--- Background server loop (runs in a coroutine/thread)
local function _server_loop()
    while M._running do
        -- Non-blocking accept with short timeout
        M._server:settimeout(0.01, "t")
        local client, err = M._server:accept()
        if client then
            -- Read request with timeout
            client:settimeout(2, "t")
            local raw, read_err = client:receive("*l") -- read first line (request line)
            
            if raw then
                -- Read remaining headers
                local full_request = raw .. "\r\n"
                local header
                repeat
                    header, read_err = client:receive("*l")
                    if header and header ~= "" then
                        full_request = full_request .. header .. "\r\n"
                    end
                until not header or header == "" or read_err
                local method, path, query, headers = _parse_request(full_request)
                if method and path then
                    local response = _handle_request(method, path, query)
                    client:send(response)
                else
                    local response = _http_response(400, "Bad Request", _json_encode({ error = "bad_request" }))
                    client:send(response)
                end
            else
                -- Silent ignore of read errors
            end
            client:close()
        elseif err and err ~= "timeout" then
            -- Only log real errors, not timeouts
            if M._running then
                -- Suppress noise; timeouts are expected in non-blocking mode
            end
        end
    end
end
--- Start the status server
function M.start(port)
    if M._running then return end
    local base_port = port or tonumber(os.getenv("EVA_STATUS_PORT")) or 8080
    M._start_time = socket.gettime()
    -- Try binding to base_port, then fallback ports up to 8090
    local bound = false
    for attempt_port = base_port, math.min(base_port + 10, 8090) do
        local s, err = socket.bind("*", attempt_port)
        if s then
            M._server = s
            M._port = attempt_port
            M._server:setoption("reuseaddr", true)
            bound = true
            break
        end
    end
    if not bound then
        print(string.format("\27[33m[STATUS_SERVER] WARNING: Could not bind to any port in range %d-%d\27[0m", base_port, math.min(base_port + 10, 8090)))
        return false
    end
    M._running = true
    M._cancel_requested = false
    -- Polling approach: M.poll() is called from the main loop for non-blocking I/O
    return true
end
--- Poll the server for new connections (call this from main loop)
function M.poll()
    if not M._running or not M._server then return end
    M._server:settimeout(0.001, "t")
    local client, err = M._server:accept()
    if client then
        -- Process request synchronously but quickly
        client:settimeout(1, "t")
        local first_line, read_err = client:receive("*l")
        if first_line then
            local method, path = first_line:match("^(%S+)%s+(%S+)")
            local query = {}
            if path then
                local qstr = path:match("\\?(.+)$")
                if qstr then
                    path = path:match("^(.-)\\?.*$") or path
                    for k, v in qstr:gmatch("(%w+)=(%w+)") do
                        query[k] = v
                    end
                end
            end
            -- Drain remaining headers
            local header
            repeat
                header, read_err = client:receive("*l")
                if not header or header == "" or read_err then break end
            until true
            if method and path then
                local response = _handle_request(method, path, query)
                client:send(response)
            else
                local response = _http_response(400, "Bad Request", _json_encode({ error = "bad_request" }))
                client:send(response)
            end
        end
        client:close()
    end
end
--- Stop the status server
function M.stop()
    M._running = false
    if M._server then
        M._server:close()
        M._server = nil
    end
    if M._thread then
        coroutine.close(M._thread)
        M._thread = nil
    end
end
--- Update status fields
function M.update_status(fields)
    _acquire_lock()
    if fields.agent_name then M._status.agent_name = fields.agent_name end
    if fields.current_turn then M._status.current_turn = fields.current_turn end
    if fields.current_stage ~= nil then M._status.current_stage = fields.current_stage end
    if fields.stage_index then M._status.stage_index = fields.stage_index end
    if fields.total_stages then M._status.total_stages = fields.total_stages end
    if fields.tokens_used then M._status.tokens_used = fields.tokens_used end
    if fields.state then M._status.state = fields.state end
    _release_lock()
end
--- Add a log line to the ring buffer
function M.add_log(line)
    _add_log_internal(tostring(line))
end
--- Check if cancel was requested
function M.is_cancel_requested()
    return M._cancel_requested
end
return M