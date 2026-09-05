local M = {}
local ipc = nil
local ok_ipc, ipc_mod = pcall(require, "ipc_mcp")
if ok_ipc then
    ipc = ipc_mod
end
local sessions = {}
local session_counter = 0
local DEFAULT_TIMEOUT = 60       -- seconds per poll
local MAX_SESSION_LIFETIME = 300 -- seconds total
local MAX_INTERACTIONS = 50      -- max input/send cycles per session
--- Start a new interactive shell session.
-- @param command string The command to execute
-- @return table|nil session info {id, output, exit_code, alive}
-- @return string|nil error message
function M.start(command)
    if not ipc then
        return nil, "IPC module (ipc_mcp) not available"
    end
    local proc = ipc.spawn_mcp(command)
    if not proc then
        return nil, "Failed to spawn process"
    end
    session_counter = session_counter + 1
    local session_id = string.format("sess_%d", session_counter)
    sessions[session_id] = {
        proc = proc,
        created_at = os.time(),
        interactions = 0,
        output_buffer = "",
        exit_code = nil,
        alive = true,
    }
    -- Initial poll: read whatever output is available immediately
    local initial_output = M._poll_output(session_id, 2) -- 2 second initial wait
    return {
        id = session_id,
        output = initial_output,
        exit_code = sessions[session_id].exit_code,
        alive = sessions[session_id].alive,
    }, nil
end
--- Send input to an active session and poll for new output.
-- @param session_id string
-- @param input string The input to send (will have newline appended)
-- @param poll_wait number|nil Seconds to wait for output (default 3)
-- @return table|nil {output, exit_code, alive}
-- @return string|nil error
function M.send_input(session_id, input, poll_wait)
    local sess = sessions[session_id]
    if not sess then
        return nil, "Unknown session: " .. tostring(session_id)
    end
    if not sess.alive then
        return nil, "Session already terminated"
    end
    -- Check lifetime
    if os.time() - sess.created_at > MAX_SESSION_LIFETIME then
        M.close(session_id)
        return nil, "Session expired (max lifetime exceeded)"
    end
    -- Check interaction limit
    if sess.interactions >= MAX_INTERACTIONS then
        M.close(session_id)
        return nil, "Session interaction limit reached"
    end
    sess.interactions = sess.interactions + 1
    -- Write input to process stdin
    local ok, err = ipc.mcp_write(sess.proc, input)
    if not ok then
        sess.alive = false
        return nil, "Failed to write to process: " .. tostring(err)
    end
    -- Poll for output
    local new_output = M._poll_output(session_id, poll_wait or 3)
    return {
        output = new_output,
        exit_code = sess.exit_code,
        alive = sess.alive,
    }, nil
end
--- Poll a session for available output without sending input.
-- @param session_id string
-- @param poll_wait number|nil Seconds to wait (default 2)
-- @return table|nil {output, exit_code, alive}
-- @return string|nil error
function M.poll(session_id, poll_wait)
    local sess = sessions[session_id]
    if not sess then
        return nil, "Unknown session: " .. tostring(session_id)
    end
    if not sess.alive then
        return nil, "Session already terminated"
    end
    local new_output = M._poll_output(session_id, poll_wait or 2)
    return {
        output = new_output,
        exit_code = sess.exit_code,
        alive = sess.alive,
    }, nil
end
--- Close and cleanup a session.
-- @param session_id string
-- @return boolean success
function M.close(session_id)
    local sess = sessions[session_id]
    if not sess then return false end
    sess.alive = false
    -- Force close by setting proc to nil (GC will handle it)
    sess.proc = nil
    sessions[session_id] = nil
    return true
end
--- Get session info (for debugging/status).
-- @param session_id string
-- @return table|nil
function M.get_info(session_id)
    local sess = sessions[session_id]
    if not sess then return nil end
    return {
        id = session_id,
        alive = sess.alive,
        interactions = sess.interactions,
        age = os.time() - sess.created_at,
        exit_code = sess.exit_code,
    }
end
--- List all active sessions.
-- @return table array of session ids
function M.list_active()
    local result = {}
    for id, sess in pairs(sessions) do
        if sess.alive then
            table.insert(result, id)
        end
    end
    return result
end
--- Close all sessions (cleanup on shutdown).
function M.close_all()
    for id in pairs(sessions) do
        M.close(id)
    end
end
--- Internal: poll process output for up to `wait_seconds`.
-- Reads available lines from the process stdout.
-- Detects process exit if read returns nil.
-- @param session_id string
-- @param wait_seconds number
-- @return string accumulated new output
function M._poll_output(session_id, wait_seconds)
    local sess = sessions[session_id]
    if not sess or not sess.alive or not sess.proc then
        return ""
    end
    local chunks = {}
    local deadline = os.time() + wait_seconds
    while os.time() <= deadline do
        local line = ipc.mcp_read(sess.proc)
        if line then
            table.insert(chunks, line)
            -- Got data, continue reading briefly for more
        else
            -- nil means pipe closed (process exited) or no data
            -- Check if process is still alive by trying a short sleep
            if #chunks > 0 then
                -- We got some data, do one more quick check
                os.execute("sleep 0.2")
                line = ipc.mcp_read(sess.proc)
                if line then
                    table.insert(chunks, line)
                else
                    break
                end
            else
                -- No data at all, wait a bit and retry
                os.execute("sleep 0.5")
                -- If we've waited the full duration with no data, break
                if os.time() >= deadline then
                    break
                end
            end
        end
    end
    local output = table.concat(chunks)
    -- Check if process has exited (pipe closed = nil on read with no data)
    -- Heuristic: if we got no output and waited full duration, process might be done
    -- More reliable: try one final read
    if #chunks == 0 then
        local final_line = ipc.mcp_read(sess.proc)
        if not final_line then
            -- Could be exited or just no output yet
            -- We'll mark as potentially exited if we've been waiting a while
            if os.time() - sess.created_at > 5 then
                sess.alive = false
                sess.exit_code = sess.exit_code or 0
            end
        end
    end
    return output
end
return M
