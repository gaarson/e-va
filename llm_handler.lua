local M = {}
local http = require("http.request")
local json = require("JSON")
local logger = require("logger")
local providers = require("llm_providers")

local function sanitize_messages(messages)
    local sanitized = {}
    for _, m in ipairs(messages) do
        if type(m.content) ~= "string" then
            logger.error("INVALID_MESSAGE: Content must be a string. Got: " .. type(m.content))
            return nil
        end
        
        -- Ensure content is a valid string for JSON (replace actual newlines with \n)
        -- This is the most common cause of "parsing the body" errors 
        local clean_content = m.content:gsub("\n", "\\n"):gsub("\r", "\\r")
        
        table.insert(sanitized, {
            role = m.role or "user",
            content = clean_content
        })
    end
    return sanitized
end

function M.send_request(profile, messages, options)
    options = options or {}
    local on_token_cb = options.on_token

    if not profile or not profile.url then
        return nil, "Invalid Profile"
    end

    local provider_name = profile.provider or "openai"
    local provider = providers.get(provider_name)

    -- local sanitized_messages = sanitize_messages(messages)
    -- if not sanitized_messages then
    --     return nil, "Failed to sanitize messages: format is incorrect"
    -- end

    local req = http.new_from_uri(profile.url)
    req.headers:upsert(":method", "POST")

    if profile.token then req.headers:upsert("Authorization", "Bearer " .. profile.token) end

    req.headers:upsert("content-type", "application/json")
    req.headers:upsert("accept", "text/event-stream")

    local payload = provider.build_payload(profile, messages, options)

    local body = json:encode(payload)
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

    for chunk in stream:each_chunk() do
        if patcher_core.consume_sigint and patcher_core.consume_sigint() then
            logger.warn("Generation forcefully interrupted by SIGINT (Ctrl+C).")
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
                local json_str = line:sub(6)
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

    if last_part and last_part.usage then
        local u = last_part.usage
        local pt = u.prompt_tokens or 0
        local ct = u.completion_tokens or 0
        local ps = u.prompt_tokens_per_sec or 0
        local cs = u.completion_tokens_per_sec or 0
        --logger.info(string.format('[USAGE] Prompt: %d tok, Completion: %d tok, P-Speed: %.1f t/s, C-Speed: %.1f t/s', pt, ct, ps, cs))
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
