local M = {}
-- Module-level state (shared across sub-modules)
M._in_flight_requests = {}
M._DEDUP_WINDOW = 30
M._DEDUP_CLEANUP_INTERVAL = 60
M._last_cleanup = nil
-- Load sub-modules
local dedup = require("llm_handler.dedup")
local stream = require("llm_handler.stream")
local request = require("llm_handler.request")
-- Re-export request functions
M.send_request = request.send_request
M.extract_content = request.extract_content
-- Inject shared state into sub-modules
dedup._in_flight_requests = M._in_flight_requests
dedup._DEDUP_WINDOW = M._DEDUP_WINDOW
dedup._DEDUP_CLEANUP_INTERVAL = M._DEDUP_CLEANUP_INTERVAL
request._last_cleanup = M._last_cleanup
return M
