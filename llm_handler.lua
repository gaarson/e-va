local M = {}
local http = require("http.request")
local json = require("JSON")
local logger = require("logger")
local providers = require("llm_providers")
local context_optimizer = require("context_optimizer")

-- Request deduplication: track in-flight requests to prevent duplicate submissions
local _in_flight_requests = {}
local _DEDUP_WINDOW = 30 -- seconds: consider requests within this window as potential duplicates
local _DEDUP_CLEANUP_INTERVAL = 60 -- seconds: purge entries older than this

local function _request_hash(profile, messages, options)
    local parts = {
        profile.model or "",
        profile.url or "",
        tostring(options and options.temperature or ""),
        tostring(options and options.max_tokens or "")
    }
    
    if messages then
        for _, msg in ipairs(messages) do
            table.insert(parts, msg.role or "")
            local content = msg.content or ""
            if type(content) == "table" then
                content = json:encode(content)
            end
            table.insert(parts, content)
        end
    end
    
    -- Быстрая сборка строки без утечек памяти
    local h = table.concat(parts, "|")
    
    -- Оптимизированный алгоритм хеширования (DJB2-подобный)
    local hash = 5381
    local len = #h
    -- Если текст гигантский, хешируем чанками (шагами), чтобы не вешать процессор
    local step = math.max(1, math.floor(len / 50000)) 
    
    for i = 1, len, step do
        local byte = string.byte(h, i)
        hash = ((hash * 33) + byte) % 4294967295
    end
    
    return string.format("%08x", hash)
end

local function _cleanup_in_flight()
    local now = require("socket").gettime()
    for hash, entry in pairs(_in_flight_requests) do
        if now - entry.timestamp > _DEDUP_CLEANUP_INTERVAL then
            _in_flight_requests[hash] = nil
        end
    end
end

function M.send_request(profile, messages, options)
    options = options or {}
    local on_token_cb = options.on_token

    if not profile or not profile.url then
        return nil, "Invalid Profile"
    end

    -- DEDUPLICATION CHECK: prevent identical in-flight requests
    local socket = require("socket")
    local req_hash = _request_hash(profile, messages, options)
    local now = socket.gettime()

    -- Periodic cleanup of stale entries
    if not M._last_cleanup or now - M._last_cleanup > _DEDUP_CLEANUP_INTERVAL then
        _cleanup_in_flight()
        M._last_cleanup = now
    end

    if _in_flight_requests[req_hash] then
        local elapsed = now - _in_flight_requests[req_hash].timestamp
        if elapsed < _DEDUP_WINDOW then
            logger.warn(string.format("[DEDUP] Blocked duplicate request (hash=%s, age=%.1fs). URL: %s", req_hash, elapsed, profile.url))
            return nil, "DUPLICATE_REQUEST_BLOCKED"
        end
    end

    -- Mark request as in-flight
    _in_flight_requests[req_hash] = { timestamp = now, profile_url = profile.url }

    local provider_name = profile.provider or "openai"
    local provider = providers.get(provider_name)

    local req = http.new_from_uri(profile.url)
    req.headers:upsert(":method", "POST")

    if profile.token then req.headers:upsert("Authorization", "Bearer " .. profile.token) end

    req.headers:upsert("content-type", "application/json")
    req.headers:upsert("accept", "text/event-stream")

    local payload = provider.build_payload(profile, messages, options)

    local body = json:encode(payload)

    -- Pre-flight validation: ensure body is valid JSON before sending
    local ok, decoded = pcall(json.decode, json, body)
    if not ok then
        logger:error("PRE-FLIGHT VALIDATION FAILED: Constructed JSON body is invalid. Error: " .. tostring(decoded))
        return nil, "Invalid JSON body constructed for API request"
    end

    req:set_body(body)

    local conn_timeout = (profile.params and profile.params.connection_timeout) or 30
    local headers, stream = req:go(conn_timeout)
    if not headers then
        _in_flight_requests[req_hash] = nil
        return nil, "Connection failed during body transmission"
    end

    local status = headers:get(":status")
    if status ~= "200" then
        local err_body = ""
        if stream then
            pcall(function() err_body = stream:get_body_as_string() end)
        end
        logger.error("API Error: " .. status, err_body)
        if status == "400" and context_optimizer.is_context_exceeded(err_body) then
            return nil, { type = 'CONTEXT_EXCEEDED', raw = 'HTTP 400', body = err_body }
        end
        -- Dedup: remove from tracking on error
        _in_flight_requests[req_hash] = nil
        return nil, "HTTP " .. status
    end

    if not payload.stream then
        -- TIMEOUT SUPPORT for non-streaming: wrap get_body_as_string with socket timeout
        local body_str
        local ok, err = pcall(function()
            local orig_timeout = socket.timeout((profile.params and profile.params.stream_timeout) or 60)
            body_str = stream:get_body_as_string()
            socket.timeout(orig_timeout) -- restore
        end)
        if not ok then
            _in_flight_requests[req_hash] = nil
            logger.warn("[NON-STREAM] Timeout reading response body: " .. tostring(err))
            return nil, "HTTP TIMEOUT"
        end
        local response = json:decode(body_str)

        if response and response.usage then
            local u = response.usage
            local pt = u.prompt_tokens or 0
            local ct = u.completion_tokens or 0
            local ps = u.prompt_tokens_per_sec or 0
            local cs = u.completion_tokens_per_sec or 0
            logger.info(string.format('[USAGE] Prompt: %d tok, Completion: %d tok, P-Speed: %.1f t/s, C-Speed: %.1f t/s', pt, ct, ps, cs))
        end

        -- Dedup: remove from tracking on completion
        _in_flight_requests[req_hash] = nil
        return response
    end

    local patcher_core = require("patcher_core")
    local full_content = ""
    local buffer = ""
    local full_reason = ""
    local full_text = ""
    local in_reasoning = false
    local was_interrupted = false
    local last_part = nil
    local first_token_received = false
    
    -- TIMEOUT DETECTION: Track last activity timestamp
    local STREAM_TIMEOUT = (profile.params and profile.params.stream_timeout) or 120 -- seconds, configurable via profile.params.stream_timeout
    local is_timeout = false
    local last_activity_time = socket.gettime()

    -- logger.info("[STREAM] Starting SSE chunk iteration. Timeout threshold: " .. STREAM_TIMEOUT .. "s")

    -- Setup ESC key monitor
    if patcher_core.setup_esc_monitor then
        patcher_core.setup_esc_monitor()
    end

    while true do
        -- Запрашиваем следующий чанк, отдавая контроль сети с таймаутом!
        local chunk, err = stream:get_next_chunk(STREAM_TIMEOUT)
        
        if not chunk then
            if err and err ~= "EOF" then
                logger.warn("[STREAM] Network error or timeout reading chunk: " .. tostring(err))
                is_timeout = true
            end
            break -- Конец стрима или ошибка/таймаут
        end

        local now = socket.gettime()
        last_activity_time = now

        -- Check for ESC key or SIGINT
        local esc_pressed = patcher_core.consume_esc and patcher_core.consume_esc()
        local sigint_pressed = patcher_core.consume_sigint and patcher_core.consume_sigint()
        
        if esc_pressed or sigint_pressed then
            if esc_pressed then
                logger.warn("Generation interrupted by ESC key.")
            else
                logger.warn("Generation forcefully interrupted by SIGINT (Ctrl+C).")
            end
            local interrupt_msg = "\n\n\27[33m[SYSTEM: GENERATION INTERRUPTED BY USER]\27[0m\n"
            full_content = full_content .. interrupt_msg
            if on_token_cb then on_token_cb(interrupt_msg) end
            was_interrupted = true
            break
        end

        buffer = buffer .. chunk

        while true do
            local line_end = buffer:find("\n")
            if not line_end then break end

            local line = buffer:sub(1, line_end - 1)
            buffer = buffer:sub(line_end + 1)

            line = line:gsub("\r", ""):gsub("^%s+", "")

            if line ~= "" and line:sub(1, 5) == "data:" then
                local json_str = line:sub(6):gsub("^%s+", ""):gsub("%s+$", "")
                if not json_str:match("%[DONE%]") then
                    local ok, part = pcall(json.decode, json, json_str)
                    if ok and part then last_part = part end

                    local c_text, c_reason = provider.extract_stream(json_str)

                    if c_reason and c_reason ~= "" then
                        if not in_reasoning then
                            in_reasoning = true
                            local token = "<think>\n" .. c_reason
                            full_content = full_content .. token
                            if on_token_cb then on_token_cb(token) end
                        else
                            full_content = full_content .. c_reason
                            if on_token_cb then on_token_cb(c_reason) end
                        end
                        full_reason = full_reason .. c_reason
                        if not first_token_received then
                            logger.info("[STREAM] First token received")
                            first_token_received = true
                        end
                    elseif c_text and c_text ~= "" then
                        if in_reasoning then
                            in_reasoning = false
                            local token = "\n\n" .. c_text
                            full_content = full_content .. token
                            if on_token_cb then on_token_cb(token) end
                        else
                            full_content = full_content .. c_text
                            if on_token_cb then on_token_cb(c_text) end
                        end
                        full_text = full_text .. c_text
                        if not first_token_received then
                            first_token_received = true
                            logger.info("[STREAM] First token received")
                        end
                    end
                end
            end
        end
    end

    -- Teardown ESC key monitor
    if patcher_core.teardown_esc_monitor then
        patcher_core.teardown_esc_monitor()
    end


    -- Dedup: remove from tracking on stream completion
    _in_flight_requests[req_hash] = nil

    if last_part and last_part.usage then
        local u = last_part.usage
        local pt = u.prompt_tokens or 0
        local ct = u.completion_tokens or 0
        local ps = u.prompt_tokens_per_sec or 0
        local cs = u.completion_tokens_per_sec or 0
        --logger.info(string.format('[USAGE] Prompt: %d tok, Completion: %d tok, P-Speed: %.1f t/s, C-Speed: %.1f t/s', pt, ct, ps, cs))
    end

    -- SAFEGUARD: Log detailed warning if full_content is empty despite HTTP 200
    if full_content == "" or full_content:match("^%s*$") then
        logger.warn("[STREAM EMPTY] HTTP 200 received but full_content is empty.")
        if last_part then
            logger.warn("[STREAM EMPTY] Last SSE part received: " .. json:encode(last_part))
        else
            logger.warn("[STREAM EMPTY] No SSE parts were parsed at all. Server may have sent [DONE] immediately.")
        end
        logger.warn("[STREAM EMPTY] full_reason length: " .. tostring(#full_reason) .. ", full_text length: " .. tostring(#full_text))
    end

    -- logger.info(string.format("[STREAM] Chunk iteration complete. Total content length: %d, full_text length: %d, timeout=%s", #full_content, #full_text, tostring(is_timeout)))

    return {
        choices = {
            {
                message = {
                    role = "assistant",
                    content = full_content
                }
            }
        },
        full_reason = full_reason,
        full_text = full_text,
        interrupted = was_interrupted,
        timed_out = is_timeout
    }
end

function M.extract_content(data, provider_name)
    provider_name = provider_name or "openai"
    local provider = providers.get(provider_name)

    return provider.extract_sync(data)
end

return M