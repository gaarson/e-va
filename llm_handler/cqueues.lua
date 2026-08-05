local cqueues = require("cqueues")
local llm_handler = require("llm_handler.request")
local logger = require("logger")

local M = {}

--- Creates and returns a new cqueues event loop
-- @return cqueue event loop object
function M.create_loop()
    local cq = cqueues.new()
    if not cq then
        return nil, "Failed to create cqueues loop"
    end
    return cq
end

--- Wraps llm_handler.send_request in a cqueues coroutine (schedules it on the loop)
-- @param cq cqueue event loop
-- @param profile table LLM profile config
-- @param messages table List of messages
-- @param options table Request options
-- @return userdata coroutine reference scheduled on the loop
function M.wrap_request(cq, profile, messages, options)
    local co = cq:wrap(function()
        return llm_handler.send_request(profile, messages, options)
    end)
    if not co then
        return nil, "Failed to wrap request in cqueues"
    end
    return co
end

--- Convenience wrapper for async LLM calls with callback
-- Schedules the request on the event loop and invokes callback(result, err) on completion
-- @param cq cqueue event loop
-- @param profile table LLM profile config
-- @param messages table List of messages
-- @param options table Request options
-- @param callback function Called with (result, err) when request completes
-- @return boolean true if scheduled successfully
function M.async_ll_call(cq, profile, messages, options, callback)
    local task = cq:wrap(function()
        local ok, result_or_err = pcall(llm_handler.send_request, profile, messages, options)
        if ok then
            if callback then callback(result_or_err, nil) end
        else
            logger.error(string.format("[ASYNC LLM CALL] Error: %s", tostring(result_or_err)))
            if callback then callback(nil, tostring(result_or_err)) end
        end
    end)
    if not task then
        if callback then callback(nil, "SCHEDULE_FAILED") end
        return false
    end
    return true
end

--- Runs the cqueues event loop until all coroutines complete
-- @param cq cqueue event loop
-- @return nil
function M.run_loop(cq)
    if not cq then
        return nil, "Invalid cqueue loop"
    end
    cq:loop()
end

return M