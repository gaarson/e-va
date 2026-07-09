local M = {}
local http = require("http.request")
local json = require("JSON")
local logger = require("logger")
local providers = require("llm_providers")
local context_optimizer = require("context_optimizer")

function M.send_request(profile, messages, options)
    options = options or {}
    local on_token_cb = options.on_token

    if not profile or not profile.url then
        return nil, "Invalid Profile"
    end

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

    local headers, stream = req:go(600)
    if not headers then return nil, "Connection failed during body transmission" end

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
        return nil, "HTTP " .. status
    end

    if not payload.stream then
        local body_str = stream:get_body_as_string()
        local response = json:decode(body_str)

        if response and response.usage then
            local u = response.usage
            local pt = u.prompt_tokens or 0
            local ct = u.completion_tokens or 0
            local ps = u.prompt_tokens_per_sec or 0
            local cs = u.completion_tokens_per_sec or 0
            logger.info(string.format('[USAGE] Prompt: %d tok, Completion: %d tok, P-Speed: %.1f t/s, C-Speed: %.1f t/s', pt, ct, ps, cs))
        end

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
    
    -- TIMEOUT DETECTION: Track last activity timestamp
    local socket = require("socket")
    local last_activity_time = socket.gettime()
    local STREAM_TIMEOUT = 120 -- seconds (2 minutes of silence = likely stuck)
    local is_timeout = false

    -- Setup ESC key monitor
    if patcher_core.setup_esc_monitor then
        patcher_core.setup_esc_monitor()
    end

    for chunk in stream:each_chunk() do
        -- Update activity timestamp on each chunk
        last_activity_time = socket.gettime()
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
                    elseif c_text and c_text ~= "" then
                        if in_reasoning then
                            in_reasoning = false
                            local token = "\n</think>\n" .. c_text
                            full_content = full_content .. token
                            if on_token_cb then on_token_cb(token) end
                        else
                            full_content = full_content .. c_text
                            if on_token_cb then on_token_cb(c_text) end
                        end
                        full_text = full_text .. c_text
                    end
                end
            end
        end
    end

    -- Teardown ESC key monitor
    if patcher_core.teardown_esc_monitor then
        patcher_core.teardown_esc_monitor()
    end

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
        interrupted = was_interrupted
    }
end

function M.extract_content(data, provider_name)
    provider_name = provider_name or "openai"
    local provider = providers.get(provider_name)

    return provider.extract_sync(data)
end

return M
