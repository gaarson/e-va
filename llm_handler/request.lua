local http = require("http.request")
local json = require("JSON")
local logger = require("logger")
local providers = require("llm_providers")
local context_optimizer = require("context_optimizer")
local dedup = require("llm_handler.dedup")
local stream = require("llm_handler.stream")
local _last_cleanup = nil
local M = {}
function M.send_request(profile, messages, options)
    options = options or {}
    local on_token_cb = options.on_token
    if not profile or not profile.url or #profile.url == 0 then
        return nil, "Invalid Profile"
    end
    logger.info(string.format("[LLM REQ] send_request called, model=%s, messages=%d", profile.model, messages and #messages or 0))
    local cqueues = require("cqueues")
    local t_hash = cqueues.monotime()
    local req_hash = dedup._request_hash(profile, messages, options)
    local hash_elapsed = cqueues.monotime() - t_hash
    
    local total_msg_size = 0
    local img_msg_count = 0
    if messages then
        for _, msg in ipairs(messages) do
            local c = msg.content or ""
            if type(c) == "table" then
                img_msg_count = img_msg_count + 1
                for _, part in ipairs(c) do
                    if part.type == "image_url" then
                        total_msg_size = total_msg_size + #(part.image_url and part.image_url.url or "")
                    elseif part.type == "text" then
                        total_msg_size = total_msg_size + #(part.text or "")
                    end
                end
            else
                total_msg_size = total_msg_size + #tostring(c)
            end
        end
    end
    logger.info(string.format("[HASH DIAG] _request_hash: time=%.4fs, msgs=%d, img_msgs=%d, total_size=%d bytes (%.1f KB)",
        hash_elapsed, messages and #messages or 0, img_msg_count, total_msg_size, total_msg_size / 1024))
    local now = cqueues.monotime()
    if not _last_cleanup or now - _last_cleanup > dedup._DEDUP_CLEANUP_INTERVAL then
        dedup._cleanup_in_flight()
        _last_cleanup = now
    end
    if dedup._in_flight_requests[req_hash] then
        local elapsed = now - dedup._in_flight_requests[req_hash].timestamp
        if elapsed < dedup._DEDUP_WINDOW then
            logger.warn(string.format("[DEDUP] Blocked duplicate request (hash=%s, age=%.1fs). URL: %s", req_hash, elapsed, profile.url))
            return nil, "DUPLICATE_REQUEST_BLOCKED"
        end
    end
    dedup._in_flight_requests[req_hash] = { timestamp = now, profile_url = profile.url }
    local provider_name = profile.provider or "openai"
    local provider = providers.get(provider_name)
    local req = http.new_from_uri(profile.url)
    req.headers:upsert(":method", "POST")
    if profile.token then req.headers:upsert("Authorization", "Bearer " .. profile.token) end
    req.headers:upsert("content-type", "application/json")
    req.headers:upsert("accept", "text/event-stream")
    req.headers:upsert("cache-control", "no-cache")
    req.headers:upsert("connection", "keep-alive")
    local payload = provider.build_payload(profile, messages, options)
    local t_encode = cqueues.monotime()
    local body = json:encode(payload)
    local encode_elapsed = cqueues.monotime() - t_encode
    logger.info(string.format("[SEND DIAG] json.encode: %.3fs, body_size=%d bytes (%.1f KB)", encode_elapsed, #body, #body/1024))
    -- JSON body validation before sending
    if type(body) ~= "string" or #body == 0 then
        logger.error("[JSON VALIDATION] Encoded body is empty or not a string.")
        dedup._in_flight_requests[req_hash] = nil
        return nil, "INVALID_JSON_BODY: Encoded body is empty or not a string"
    end
    if body:sub(1, 1) ~= "{" or body:sub(-1) ~= "}" then
        logger.error(string.format("[JSON VALIDATION] Body does not look like a JSON object. Starts with '%s', ends with '%s'. Preview: %s",
            body:sub(1, 1), body:sub(-1), body:sub(1, 200)))
        dedup._in_flight_requests[req_hash] = nil
        return nil, string.format("INVALID_JSON_BODY: Body does not start with '{{' or end with '}}'. Preview: %s", body:sub(1, 200))
    end
    local ok, decoded = pcall(json.decode, json, body)
    if not ok then
        logger.error(string.format("[JSON VALIDATION] Round-trip decode failed: %s. Preview: %s",
            tostring(decoded), body:sub(1, 200)))
        dedup._in_flight_requests[req_hash] = nil
        return nil, string.format("INVALID_JSON_BODY: Round-trip decode failed. Preview: %s", body:sub(1, 200))
    end
    req:set_body(body)
    req.headers:delete("expect")
    local conn_timeout = (profile.params and profile.params.connection_timeout) or 30
    logger.info(string.format("[LLM CONNECTION DIAG] URL=%s, Model=%s, Timeout=%ds, BodySize=%d bytes",
        profile.url, profile.model or "unknown", conn_timeout, #body))
    logger.info(string.format("[LLM CONNECTION DIAG] Headers: Authorization=Bearer ***%s, Accept=text/event-stream",
        string.sub(profile.token or "", -4)))
    logger.info("[SEND DIAG] Calling req:go with timeout=" .. conn_timeout)
    local t_send = cqueues.monotime()
    local ok, headers_or_err, stream_obj_or_err = pcall(function() return req:go(conn_timeout) end)
    local send_elapsed = cqueues.monotime() - t_send
    if ok then
        headers, stream_obj = headers_or_err, stream_obj_or_err
        logger.info(string.format("[SEND DIAG] req:go completed: %.3fs", send_elapsed))
    else
        -- Classify the error
        local err_msg = tostring(headers_or_err)
        local err_class = "UNKNOWN"
        if err_msg:match("refused") or err_msg:match("Connection refused") then
            err_class = "CONNECTION_REFUSED"
        elseif err_msg:match("timeout") or err_msg:match("timed out") or err_msg:match("TIMEOUT") then
            err_class = "TIMEOUT"
        elseif err_msg:match("name") or err_msg:match("resolve") or err_msg:match("DNS") or err_msg:match("getaddrinfo") then
            err_class = "DNS_FAILURE"
        elseif err_msg:match("ssl") or err_msg:match("SSL") or err_msg:match("certificate") or err_msg:match("TLS") then
            err_class = "SSL_ERROR"
        elseif err_msg:match("reset") or err_msg:match("RESET") then
            err_class = "CONNECTION_RESET"
        elseif err_msg:match("network") or err_msg:match("Network") then
            err_class = "NETWORK_UNREACHABLE"
        end
        logger.error(string.format("[LLM CONNECTION DIAG] FAILED: class=%s, elapsed=%.3fs, err=%s",
            err_class, send_elapsed, err_msg))
        logger.error(string.format("[LLM_CONN_FAIL] class=%s, url=%s, elapsed=%.3fs, err=%s",
            err_class, profile.url, send_elapsed, err_msg))
        dedup._in_flight_requests[req_hash] = nil
        return nil, string.format("CONNECTION_FAILED [%s]: %s", err_class, err_msg)
    end
    if not headers then
        local diag_detail = string.format("headers=nil, stream_obj=%s, url=%s, model=%s, elapsed=%.3fs, body_size=%d",
            tostring(stream_obj), profile.url, profile.model or "unknown", send_elapsed, #body)
        logger.error(string.format("[LLM NIL HEADERS] %s", diag_detail))
        logger.error(string.format("[LLM_NIL_HEADERS] url=%s, model=%s, elapsed=%.3fs, stream_obj=%s, body_size=%d",
            profile.url, profile.model or "unknown", send_elapsed, tostring(stream_obj), #body))
        io.stderr:write("\n\27[31m========================================\27[0m\n")
        io.stderr:write("\27[31m     [NIL HEADERS RESPONSE]\27[0m\n")
        io.stderr:write("\27[31m========================================\27[0m\n")
        io.stderr:write(string.format("\27[31m  URL: %s\27[0m\n", profile.url))
        io.stderr:write(string.format("\27[31m  Model: %s\27[0m\n", profile.model or "unknown"))
        io.stderr:write(string.format("\27[31m  Elapsed: %.3fs\27[0m\n", send_elapsed))
        io.stderr:write(string.format("\27[31m  stream_obj: %s\27[0m\n", tostring(stream_obj)))
        io.stderr:write("\27[31m  Diagnosis: req:go() succeeded but returned nil headers.\27[0m\n")
        io.stderr:write("\27[31m  Possible causes:\27[0m\n")
        io.stderr:write("\27[31m    1. Server closed connection before sending headers\27[0m\n")
        io.stderr:write("\27[31m    2. HTTP/1.1 vs HTTP/2 protocol mismatch\27[0m\n")
        io.stderr:write("\27[31m    3. Proxy or firewall intercepting response\27[0m\n")
        io.stderr:write("\27[31m========================================\27[0m\n")
        dedup._in_flight_requests[req_hash] = nil
        return nil, string.format("NIL_HEADERS [%s]: %s", profile.url, diag_detail)
    end
    local status = headers:get(":status")
    local content_type = headers:get("content-type") or ""
    local transfer_encoding = headers:get("transfer-encoding") or ""
    logger.info(string.format("[RESPONSE HEADERS] status=%s, content-type=%s, transfer-encoding=%s", status, content_type, transfer_encoding))
    if status ~= "200" then
        local err_body = ""
        if stream_obj then
            pcall(function() err_body = stream_obj:get_body_as_string() end)
        end
        -- Structured logging via json_logger
        logger.error(string.format("[HTTP_ERROR] status=%s, url=%s, body_len=%d, body_preview=%s",
            status, profile.url, #err_body, err_body:sub(1, 200)))
        -- Full error body in info log for debugging
        logger.info(string.format("[HTTP ERROR BODY] status=%s, body=%s", status, err_body))
        -- Colored stderr block
        local preview = err_body:sub(1, 200)
        io.stderr:write("\n\27[31m========================================\27[0m\n")
        io.stderr:write("\27[31m     [HTTP ERROR]\27[0m\n")
        io.stderr:write("\27[31m========================================\27[0m\n")
        io.stderr:write(string.format("\27[31m  Status: %s\27[0m\n", status))
        io.stderr:write(string.format("\27[31m  URL: %s\27[0m\n", profile.url))
        io.stderr:write(string.format("\27[31m  Model: %s\27[0m\n", profile.model or "unknown"))
        io.stderr:write(string.format("\27[31m  Body (%d bytes): %s\27[0m\n", #err_body, preview))
        io.stderr:write("\27[31m========================================\27[0m\n")
        if status == "400" and context_optimizer.is_context_exceeded(err_body) then
            return nil, { type = 'CONTEXT_EXCEEDED', raw = 'HTTP 400', body = err_body }
        end
        dedup._in_flight_requests[req_hash] = nil
        return nil, "HTTP " .. status
    end
    if not payload.stream then
        local body_str
        local ok, err = pcall(function()
            body_str = stream_obj:get_body_as_string()
        end)
        if not ok then
            dedup._in_flight_requests[req_hash] = nil
            logger.warn("[NON-STREAM] Error reading response body: " .. tostring(err))
            return nil, "HTTP_BODY_READ_ERROR"
        end
        local ok, response = pcall(json.decode, json, body_str)
        if not ok then
            dedup._in_flight_requests[req_hash] = nil
            logger.error("[JSON PARSE ERROR] Malformed LLM response: " .. tostring(response))
            return nil, "MALFORMED_JSON_RESPONSE"
        end
        if response and response.usage then
            local u = response.usage
            local pt = u.prompt_tokens or 0
            local ct = u.completion_tokens or 0
            local ps = u.prompt_tokens_per_sec or 0
            local cs = u.completion_tokens_per_sec or 0
            logger.info(string.format('[USAGE] Prompt: %d tok, Completion: %d tok, P-Speed: %.1f t/s, C-Speed: %.1f t/s', pt, ct, ps, cs))
        end
        dedup._in_flight_requests[req_hash] = nil
        return response
    end
    local ok, result_or_err = pcall(stream.process_stream, stream_obj, profile, provider, on_token_cb)
    if not ok then
        dedup._in_flight_requests[req_hash] = nil
        logger.error(string.format("[STREAM ERROR] Lua error during stream processing: %s", tostring(result_or_err)))
        return nil, "STREAM_PROCESSING_ERROR"
    end
    local result = result_or_err
    dedup._in_flight_requests[req_hash] = nil
    if result.usage then
        local u = result.usage
        local pt = u.prompt_tokens or 0
        local ct = u.completion_tokens or 0
        local ps = u.prompt_tokens_per_sec or 0
        local cs = u.completion_tokens_per_sec or 0
        --logger.info(string.format('[USAGE] Prompt: %d tok, Completion: %d tok, P-Speed: %.1f t/s, C-Speed: %.1f t/s', pt, ct, ps, cs))
    end
    return result
end
function M.extract_content(data, provider_name)
    provider_name = provider_name or "openai"
    local provider = providers.get(provider_name)
    return provider.extract_sync(data)
end
return M