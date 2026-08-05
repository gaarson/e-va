local logger = require("logger")
local M = {}
function M.process_stream(stream, profile, provider, on_token_cb)
    local patcher_core = require("patcher_core")
    local cqueues = require("cqueues")
    local json = require("JSON")
    local content_parts = {}
    local text_parts = {}
    local reason_parts = {}
    local buffer = ""
    local in_reasoning = false
    local was_interrupted = false
    local last_part = nil
    local first_token_received = false
    local STREAM_TIMEOUT = (profile.params and profile.params.stream_timeout) or 600
    local is_timeout = false
    local last_activity_time = cqueues.monotime()
    local BUFFER_LIMIT = 65536 -- 64KB
    local last_parse_time = cqueues.monotime()
    if patcher_core.setup_esc_monitor then
        patcher_core.setup_esc_monitor()
    end
    while true do
        local chunk, err = stream:get_next_chunk(STREAM_TIMEOUT)
        if not chunk then
            if err and err ~= "EOF" then
                logger.warn("[STREAM] Network error or timeout reading chunk: " .. tostring(err))
                is_timeout = true
            end
            break
        end
        local now = cqueues.monotime()
        last_activity_time = now
        -- Debug logging for chunks
        if logger.debug then
            logger.debug(string.format("[STREAM] Remaining buffer after loop: %d bytes", #buffer))
        end
        local esc_pressed = patcher_core.consume_esc and patcher_core.consume_esc()
        local sigint_pressed = patcher_core.consume_sigint and patcher_core.consume_sigint()
        
        if esc_pressed or sigint_pressed then
            if esc_pressed then
                logger.warn("Generation interrupted by ESC key.")
            else
                logger.warn("Generation forcefully interrupted by SIGINT (Ctrl+C).")
            end
            local interrupt_msg = "\n\n\27[33m[SYSTEM: GENERATION INTERRUPTED BY USER]\27[0m\n"
            table.insert(content_parts, interrupt_msg)
            if on_token_cb then on_token_cb(interrupt_msg) end
            was_interrupted = true
            break
        end
        buffer = buffer .. chunk
        -- Force-flush buffer if it exceeds limit without newlines (malformed SSE protection)
        if #buffer > BUFFER_LIMIT then
            local newline_pos = buffer:find("\n")
            if not newline_pos then
                logger.warn(string.format("[STREAM] Buffer exceeded %d bytes without newline. Force-flushing.", BUFFER_LIMIT))
                -- Treat entire buffer as one line
                local line = buffer:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
                buffer = ""
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
                                table.insert(content_parts, token)
                                if on_token_cb then on_token_cb(token) end
                            else
                                table.insert(content_parts, c_reason)
                                if on_token_cb then on_token_cb(c_reason) end
                            end
                            table.insert(reason_parts, c_reason)
                        elseif c_text and c_text ~= "" then
                            if in_reasoning then
                                in_reasoning = false
                                local token = "\n\n" .. c_text
                                table.insert(content_parts, token)
                                if on_token_cb then on_token_cb(token) end
                            else
                                table.insert(content_parts, c_text)
                                if on_token_cb then on_token_cb(c_text) end
                            end
                            table.insert(text_parts, c_text)
                        end
                    end
                end
            end
        end
        while true do
            local line_end = buffer:find("\n")
            if not line_end then break end
            local line = buffer:sub(1, line_end - 1)
            buffer = buffer:sub(line_end + 1)
            line = line:gsub("\r", ""):gsub("^%s+", "")
            -- Handle SSE event: lines (optional metadata)
            if line:sub(1, 6) == "event:" then
                last_parse_time = cqueues.monotime()
            elseif line ~= "" and line:sub(1, 5) == "data:" then
                last_parse_time = cqueues.monotime()
                local json_str = line:sub(6):gsub("^%s+", ""):gsub("%s+$", "")
                if not json_str:match("%[DONE%]") then
                    local ok, part = pcall(json.decode, json, json_str)
                    if ok and part then last_part = part end
                    local c_text, c_reason = provider.extract_stream(json_str)
                    if c_reason and c_reason ~= "" then
                        if not in_reasoning then
                            in_reasoning = true
                            local token = "<think>\n" .. c_reason
                            table.insert(content_parts, token)
                            if on_token_cb then on_token_cb(token) end
                        else
                            table.insert(content_parts, c_reason)
                            if on_token_cb then on_token_cb(c_reason) end
                        end
                        table.insert(reason_parts, c_reason)
                        if not first_token_received then
                            logger.info("[STREAM] First token received")
                            first_token_received = true
                        end
                    elseif c_text and c_text ~= "" then
                        if in_reasoning then
                            in_reasoning = false
                            local token = "\n\n" .. c_text
                            table.insert(content_parts, token)
                            if on_token_cb then on_token_cb(token) end
                        else
                            table.insert(content_parts, c_text)
                            if on_token_cb then on_token_cb(c_text) end
                        end
                        table.insert(text_parts, c_text)
                        if not first_token_received then
                            logger.info("[STREAM] First token received")
                            first_token_received = true
                        end
                    end
                end
            end
        end
        -- Warn if buffer is growing without producing lines
        if #buffer > 4096 then
            local elapsed = cqueues.monotime() - last_parse_time
            if elapsed > 5 then
                logger.warn(string.format("[STREAM] Buffer stagnation: %d bytes buffered, %.1fs since last parse", #buffer, elapsed))
            end
        end
    end
    -- Parse any remaining content in buffer after stream ends
    if #buffer > 0 then
        buffer = buffer:gsub("\r", ""):gsub("%s+$", "")
        if buffer ~= "" and buffer:sub(1, 5) == "data:" then
            local json_str = buffer:sub(6):gsub("^%s+", ""):gsub("%s+$", "")
            if not json_str:match("%[DONE%]") then
                local ok, part = pcall(json.decode, json, json_str)
                if ok and part then last_part = part end
                local c_text, c_reason = provider.extract_stream(json_str)
                if c_reason and c_reason ~= "" then
                    if not in_reasoning then
                        in_reasoning = true
                        local token = "<think>\n" .. c_reason
                        table.insert(content_parts, token)
                        if on_token_cb then on_token_cb(token) end
                    else
                        table.insert(content_parts, c_reason)
                        if on_token_cb then on_token_cb(c_reason) end
                    end
                    table.insert(reason_parts, c_reason)
                elseif c_text and c_text ~= "" then
                    if in_reasoning then
                        in_reasoning = false
                        local token = "\n\n" .. c_text
                        table.insert(content_parts, token)
                        if on_token_cb then on_token_cb(token) end
                    else
                        table.insert(content_parts, c_text)
                        if on_token_cb then on_token_cb(c_text) end
                    end
                    table.insert(text_parts, c_text)
                end
            end
        end
        if logger.debug then
            logger.debug(string.format("[STREAM] Remaining buffer after loop: %d bytes", #buffer))
        end
    end
    if patcher_core.teardown_esc_monitor then
        patcher_core.teardown_esc_monitor()
    end
    local full_content = table.concat(content_parts)
    local full_text = table.concat(text_parts)
    local full_reason = table.concat(reason_parts)
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
        interrupted = was_interrupted,
        timed_out = is_timeout,
        usage = last_part and last_part.usage or nil
    }
end
return M