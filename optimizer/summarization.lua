local llm_handler = require("llm_handler")
local logger = require("logger")
local utils = require("utils")
local M = {}
-- Reset summarization counter periodically
local function _reset_summarization_counter()
    local now = os.time()
    if now - M._llm_summarization_reset_time > 60 then
        M._llm_summarization_count = 0
        M._llm_summarization_reset_time = now
    end
end
function M.should_summarize_with_llm(msg, config)
    if not msg or not msg.content then return false end
    local llm_cfg = (config and config.COMPRESSION and config.COMPRESSION.llm_summarization) or {}
    if not llm_cfg.enabled then return false end
    local min_len = llm_cfg.min_message_length or M._MIN_MESSAGE_LENGTH
    local max_per_turn = llm_cfg.max_summaries_per_turn or M._MAX_SUMMARIES_PER_TURN
    if #msg.content < min_len then return false end
    _reset_summarization_counter()
    if M._llm_summarization_count >= max_per_turn then return false end
    if not msg.content:match("<thinking>") and not msg.content:match("reasoning") and
       not msg.content:match("analysis") and not msg.content:match("consider") then
        return false
    end
    if msg.content:match("||| COMMAND |||") then return false end
    return true
end
function M.summarize_message(msg, config)
    local opt_agent = config and config.OPTIMIZER_AGENT
    if not opt_agent then
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return nil
    end
    if not msg or not msg.content or #msg.content == 0 then return nil end
    local content_hash = string.format("%x", #msg.content) .. "_" .. string.sub(msg.content, 1, 50)
    if M._summary_cache[content_hash] then
        logger.info("[OPTIMIZER] Using cached summary for message.")
        return M._summary_cache[content_hash]
    end
    local now = os.time()
    local rate_limit = (config and config.COMPRESSION and config.COMPRESSION.llm_summarization and config.COMPRESSION.llm_summarization.rate_limit_seconds) or 30
    if now - M._last_llm_call_time < rate_limit then
        logger.info("[OPTIMIZER] SKIPPED: Rate limited for LLM summarization.")
        return nil
    end
    _reset_summarization_counter()
    if M._llm_summarization_count >= (config and config.COMPRESSION and config.COMPRESSION.llm_summarization and config.COMPRESSION.llm_summarization.max_summaries_per_turn or M._MAX_SUMMARIES_PER_TURN) then
        logger.info("[OPTIMIZER] SKIPPED: Max summaries per turn reached.")
        return nil
    end
    logger.info("[OPTIMIZER] Summarizing message with LLM...")
    local max_input = 8000
    local truncated_content = msg.content
    if #msg.content > max_input then
        local half = math.floor(max_input / 2)
        truncated_content = msg.content:sub(1, half) .. "\n[...TRUNCATED...]\n" .. msg.content:sub(-half)
    end
    local prompt = string.format([[
You are an expert Message Summarization Agent. Your job is to create a concise summary of a long assistant message while preserving all key decisions, actions, and conclusions.
ORIGINAL MESSAGE (truncated if too long):
%s
INSTRUCTIONS:
1. Extract key decisions, actions taken, and conclusions
2. Preserve any tool names, file paths, or specific technical details
3. Keep error messages and important warnings intact
4. Summarize verbose reasoning into 1-2 sentences per key point
5. Return ONLY the summary text, nothing else
Output the summary as plain text without any markdown formatting.
]], truncated_content)
    local messages = {
        { role = "system", content = "You are a Message Summarization AI. Output ONLY the concise summary." },
        { role = "user", content = prompt }
    }
    M._last_llm_call_time = os.time()
    M._llm_summarization_count = M._llm_summarization_count + 1
    local res, err = llm_handler.send_request(opt_agent, messages, {
        override_params = { stream = false, temperature = 0.1, max_tokens = 512, stream_timeout = 30 }
    })
    if not res then
        logger.warn("[OPTIMIZER] Failed to summarize message: " .. tostring(err))
        return nil
    end
    local content = llm_handler.extract_content(res)
    if not content then return nil end
    local summary = utils.trim(content:gsub("`+", ""))
    if #summary > 0 then
        if #M._summary_cache >= M.M._summary_cache_max then
            for k in pairs(M._summary_cache) do
                M._summary_cache[k] = nil
                break
            end
        end
        M._summary_cache[content_hash] = summary
        logger.info("[OPTIMIZER] Summarized message: " .. summary:sub(1, 80) .. "...")
        return summary
    else
        logger.warn("[OPTIMIZER] Empty summary returned.")
        return nil
    end
end
function M.summarize_conversation_segment(messages, max_tokens, config)
    if not messages or #messages == 0 then return "" end
    local opt_agent = config and config.OPTIMIZER_AGENT
    if not opt_agent then
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return ""
    end
    local now = os.time()
    local rate_limit = (config and config.COMPRESSION and config.COMPRESSION.llm_summarization and config.COMPRESSION.llm_summarization.rate_limit_seconds) or 30
    if now - M._last_llm_call_time < rate_limit then
        logger.info("[OPTIMIZER] SKIPPED: Rate limited for segment summarization.")
        return ""
    end
    logger.info("[OPTIMIZER] Summarizing conversation segment with LLM...")
    local compact_msgs = {}
    local total_len = 0
    local max_total = 10000
    for i, msg in ipairs(messages) do
        if msg and msg.content then
            local role = msg.role or "unknown"
            local content = msg.content
            if #content > 2000 then
                content = content:sub(1, 1000) .. "\n[...TRUNCATED...]\n" .. content:sub(-1000)
            end
            table.insert(compact_msgs, string.format("[%s]: %s", role, content))
            total_len = total_len + #content
            if total_len > max_total then break end
        end
    end
    local prompt = string.format([[
You are an expert Conversation Summarization Agent. Your job is to create a concise summary of a conversation segment while preserving all key decisions, actions, and conclusions.
CONVERSATION SEGMENT:
%s
INSTRUCTIONS:
1. Summarize the flow of the conversation
2. Extract key decisions, actions taken, and conclusions
3. Preserve any tool names, file paths, or specific technical details
4. Keep error messages and important warnings intact
5. Return ONLY the summary text, nothing else
Output the summary as plain text without any markdown formatting.
]], table.concat(compact_msgs, "\n\n"))
    local messages = {
        { role = "system", content = "You are a Conversation Summarization AI. Output ONLY the concise summary." },
        { role = "user", content = prompt }
    }
    M._last_llm_call_time = os.time()
    local res, err = llm_handler.send_request(opt_agent, messages, {
        override_params = { stream = false, temperature = 0.1, max_tokens = 1024, stream_timeout = 30 }
    })
    if not res then
        logger.warn("[OPTIMIZER] Failed to summarize conversation segment: " .. tostring(err))
        return ""
    end
    local content = llm_handler.extract_content(res)
    if not content then return "" end
    local summary = utils.trim(content:gsub("`+", ""))
    if #summary > 0 then
        logger.info("[OPTIMIZER] Summarized conversation segment: " .. summary:sub(1, 80) .. "...")
        return summary
    else
        logger.warn("[OPTIMIZER] Empty summary returned for conversation segment.")
        return ""
    end
end
return M
