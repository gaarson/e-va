
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


    if not profile or not profile.url then

        return nil, "Invalid Profile"

    end

    logger.info(string.format("[LLM REQ] send_request called, model=%s, messages=%d", profile.model, messages and #messages or 0))

    

    local socket = require("socket")

    local t_hash = socket.gettime()

    local req_hash = dedup._request_hash(profile, messages, options)

    local hash_elapsed = socket.gettime() - t_hash

    

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

    local now = socket.gettime()


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


    local payload = provider.build_payload(profile, messages, options)

    local t_encode = socket.gettime()

    local body = json:encode(payload)

    local encode_elapsed = socket.gettime() - t_encode

    logger.info(string.format("[SEND DIAG] json.encode: %.3fs, body_size=%d bytes (%.1f KB)", encode_elapsed, #body, #body/1024))

    req:set_body(body)

    req.headers:delete("expect")

    local conn_timeout = (profile.params and profile.params.connection_timeout) or 30

    logger.info("[SEND DIAG] Calling req:go with timeout=" .. conn_timeout)

    local t_send = socket.gettime()

    local headers, stream_obj = req:go(conn_timeout)

    local send_elapsed = socket.gettime() - t_send

    logger.info(string.format("[SEND DIAG] req:go completed: %.3fs", send_elapsed))

    if not headers then

        dedup._in_flight_requests[req_hash] = nil

        return nil, "Connection failed during body transmission"

    end


    local status = headers:get(":status")

    if status ~= "200" then

        local err_body = ""

        if stream_obj then

            pcall(function() err_body = stream_obj:get_body_as_string() end)

        end

        logger.error("API Error: " .. status, err_body)

        if status == "400" and context_optimizer.is_context_exceeded(err_body) then

            return nil, { type = 'CONTEXT_EXCEEDED', raw = 'HTTP 400', body = err_body }

        end

        dedup._in_flight_requests[req_hash] = nil

        return nil, "HTTP " .. status

    end


    if not payload.stream then

        local body_str

        local ok, err = pcall(function()

            local orig_timeout = socket.timeout((profile.params and profile.params.stream_timeout) or 60)

            body_str = stream_obj:get_body_as_string()

            socket.timeout(orig_timeout)

        end)

        if not ok then

            dedup._in_flight_requests[req_hash] = nil

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


        dedup._in_flight_requests[req_hash] = nil

        return response

    end


    local result = stream.process_stream(stream_obj, profile, provider, on_token_cb)

    

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

