local M = {}
local llm_handler = require("llm_handler")
local json = require("JSON")
local logger = require("logger")
local utils = require("utils")
-- Caching state for optimization results
M._last_optimization = {
    timestamp = 0,
    context_size = 0,
    result = nil
}
M._OPTIMIZE_THRESHOLD = 0.10  -- Only re-run if context grew by >10%
-- Rate limiting: prevent hammering the API
M._last_llm_call_time = 0
M._MIN_CALL_INTERVAL = 2  -- Minimum seconds between optimizer LLM calls
-- Helper: compute approximate context size
local function _compute_context_size(ctx)
    local size = 0
    if ctx.knowledge_base then
        for _, content in pairs(ctx.knowledge_base) do
            size = size + #(content or "")
        end
    end
    if ctx.history then
        for _, agent_msgs in pairs(ctx.history) do
            if type(agent_msgs) == "table" then
                for _, msg in ipairs(agent_msgs) do
                    size = size + #(msg.content or "")
                end
            end
        end
    end
    return size
end
-- Deep copy a table (handles nested tables, not circular refs)
local function _deep_copy_table(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = _deep_copy_table(v)
    end
    return copy
end
function M.get_last_result()
    return M._last_optimization.result
end
function M.analyze_and_optimize(ctx, config)
    -- RATE LIMITING: Skip if we called the LLM recently
    local now = os.time()
    if now - M._last_llm_call_time < M._MIN_CALL_INTERVAL then
        logger.info(string.format("[OPTIMIZER] SKIPPED: Rate limited. Last call %.1fs ago (< %ds)", 
            now - M._last_llm_call_time, M._MIN_CALL_INTERVAL))
        return
    end
    -- CACHING: Skip if context hasn't grown significantly since last optimization
    local current_size = _compute_context_size(ctx)
    local last = M._last_optimization
    if last.timestamp > 0 and last.context_size > 0 then
        local growth_ratio = (current_size - last.context_size) / last.context_size
        if growth_ratio <= M._OPTIMIZE_THRESHOLD then
            logger.info(string.format("[OPTIMIZER] SKIPPED: Context growth %.1f%% <= %.1f%% threshold", 
                growth_ratio * 100, M._OPTIMIZE_THRESHOLD * 100))
            return
        end
    end
    -- Run optimization synchronously with atomic state application
    M._do_analyze_and_optimize(ctx, config)
end


-- Internal: actual optimization logic (runs synchronously with atomic state application)
function M._do_analyze_and_optimize(ctx, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then 
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return 
    end
    logger.info("[OPTIMIZER] Starting context analysis...")
    -- 1. Take a SNAPSHOT of ctx state BEFORE calling LLM (prevents partial corruption)
    local snapshot = {
        knowledge_base_keys = {},
        pinned_files = _deep_copy_table(ctx.pinned_files or {}),
        task_summary = ctx.task_summary or "None",
        current_task_index = ctx.current_task_index or 0,
        execution_plan_len = ctx.execution_plan and #ctx.execution_plan or 0,
        last_actions = {},
        thoughts_text = ctx.get_recent_thoughts_text and ctx:get_recent_thoughts_text() or ""
    }
    for path, _ in pairs(ctx.knowledge_base) do table.insert(snapshot.knowledge_base_keys, path) end
    local start_idx = math.max(1, #(ctx.last_actions or {}) - 5)
    for i = start_idx, #(ctx.last_actions or {}) do
        if ctx.last_actions[i] then
            table.insert(snapshot.last_actions, ctx.last_actions[i].summary or "")
        end
    end
    local context_brief = string.format(
        "TASK SUMMARY: %s\nCURRENT STEP: %d/%d\nLOADED FILES: %s\nRECENT ACTIONS: %s\nPINNED: %s\nTHOUGHTS: %s",
        snapshot.task_summary,
        snapshot.current_task_index,
        snapshot.execution_plan_len,
        table.concat(snapshot.knowledge_base_keys, ", "),
        table.concat(snapshot.last_actions, " | "),
        table.concat(snapshot.pinned_files and next(snapshot.pinned_files) and {table.concat(snapshot.pinned_files, ", ")} or {"None"}, ", "),
        snapshot.thoughts_text
    )
    -- 2. Build prompt for Optimizer
    local prompt = string.format([[
You are an autonomous Context Optimization Agent. Your job is to analyze the current state of the main agent's memory and optimize it to prevent token overflow and maintain focus.
CURRENT CONTEXT BRIEF:
%s
INSTRUCTIONS:
1. Update the TASK SUMMARY to accurately reflect the current progress and next immediate goal.
2. Identify files that are NO LONGER NEEDED and should be removed from memory to save tokens.
3. Identify critical files that should be PINNED.
Respond STRICTLY with a valid JSON object. Do not include any markdown formatting or extra text.
{
  "new_summary": "Updated concise summary of the task and current state.",
  "files_to_remove": ["path/to/old_file.lua"],
  "files_to_pin": ["path/to/critical.h"]
}
]], context_brief)
    local messages = {
        { role = "system", content = "You are a Context Optimization AI. Output ONLY valid JSON." },
        { role = "user", content = prompt }
    }
    -- 3. Synchronous non-streaming call with timeout
    M._last_llm_call_time = os.time()
    local res, err = llm_handler.send_request(opt_agent, messages, { 
        override_params = { stream = false, temperature = 0.1, stream_timeout = 30 } 
    })
    if not res then
        logger.warn("[OPTIMIZER] Failed to get response: " .. tostring(err))
        return
    end
    local content = llm_handler.extract_content(res)
    if not content then return end
    -- 4. Parse JSON response
    local json_match = utils.trim(content:gsub("`+", ""))
    local status, payload = pcall(function() return json:decode(json_match) end)
    if status and type(payload) == "table" then
        -- ATOMIC APPLICATION: Apply all mutations after successful LLM response
        if payload.new_summary and type(payload.new_summary) == "string" then
            ctx:update_summary(payload.new_summary)
            logger.info("[OPTIMIZER] Updated summary.")
        end
        if payload.files_to_remove and type(payload.files_to_remove) == "table" then
            for _, f in ipairs(payload.files_to_remove) do
                if ctx.knowledge_base[f] then
                    ctx.knowledge_base[f] = nil
                    ctx.file_states[f] = nil
                    ctx.file_access_rank[f] = nil
                    logger.info("[OPTIMIZER] Removed from memory: " .. f)
                end
            end
        end
        if payload.files_to_pin and type(payload.files_to_pin) == "table" then
            for _, f in ipairs(payload.files_to_pin) do
                if ctx.knowledge_base[f] then
                    ctx:pin_file(f)
                    logger.info("[OPTIMIZER] Pinned: " .. f)
                end
            end
        end
        logger.info("[OPTIMIZER] Cycle complete.")
        -- Cache the result
        M._last_optimization.timestamp = os.time()
        M._last_optimization.context_size = _compute_context_size(ctx)
        M._last_optimization.result = payload
    else
        local debug_snip = json_match:sub(1, 100) .. "..."
        logger.warn("[OPTIMIZER] Failed to parse JSON response. Engine saw: " .. debug_snip)
    end
end

function M.summarize_unclosed_thought(unclosed_text, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then 
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return nil 
    end

    if not unclosed_text or #utils.trim(unclosed_text) == 0 then
        logger.warn("[OPTIMIZER] No unclosed text provided.")
        return nil
    end

    logger.info("[OPTIMIZER] Summarizing unclosed thought...")

    -- Form the summarization request
    local prompt = string.format([[
You are an expert Thought Summarization Agent. Your job is to analyze incomplete or unclosed thinking text and summarize it into a concise, actionable output.

UNCLOSED THOUGHT:
%s

INSTRUCTIONS:
1. Identify the core intent and key points of the incomplete thought
2. Summarize the thought in 1-3 concise sentences
3. Focus on actionable insights or next steps
4. Return ONLY the summarized text, nothing else

Return the summary as plain text without any markdown formatting or extra text.
]], unclosed_text)

    local messages = {
        { role = "system", content = "You are a Thought Summarization AI. Output ONLY the concise summary." },
        { role = "user", content = prompt }
    }

    -- Non-streaming call to the optimizer model with timeout
    M._last_llm_call_time = os.time()
    local res, err = llm_handler.send_request(opt_agent, messages, { override_params = { stream = false, temperature = 0.1, stream_timeout = 30 } })
    if not res then
        logger.warn("[OPTIMIZER] Failed to get response: " .. tostring(err))
        return nil
    end

    local content = llm_handler.extract_content(res)
    if not content then return nil end

    -- Clean up the response
    local summary = utils.trim(content:gsub("`+", ""))

    if #summary > 0 then
        logger.info("[OPTIMIZER] Summarized unclosed thought.")
        return summary
    else
        logger.warn("[OPTIMIZER] Empty summary returned.")
        return nil
    end
end

function M.generate_continuation_prompt(ctx, config)
    local opt_agent = config.OPTIMIZER_AGENT
    if not opt_agent then
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return nil
    end

    -- 1. Gather context: last assistant message, task summary, execution plan
    -- NOTE: ctx.history is keyed by agent_name (e.g. ctx.history["ARCHITECT"]), NOT a flat array.
    -- We must iterate over all agent histories to find the most recent assistant message.
    local last_assistant = ""
    if ctx.history and type(ctx.history) == "table" then
        for _, agent_msgs in pairs(ctx.history) do
            if type(agent_msgs) == "table" then
                for i = #agent_msgs, 1, -1 do
                    local msg = agent_msgs[i]
                    if msg and msg.role == "assistant" and msg.content and #msg.content > 0 then
                        if #msg.content > #last_assistant then
                            last_assistant = msg.content
                        end
                        break -- only need the last assistant msg per agent
                    end
                end
            end
        end
    end

    local task_summary = ctx.task_summary or "No task summary available."

    local plan_text = "No execution plan."
    if ctx.execution_plan and #ctx.execution_plan > 0 then
        plan_text = ""
        for i, step in ipairs(ctx.execution_plan) do
            plan_text = plan_text .. i .. ". " .. (step.description or step.summary or step) .. "\n"
        end
    end

    local recent_actions = ""
    if ctx.last_actions and #ctx.last_actions > 0 then
        local actions_list = {}
        local start_idx = math.max(1, #ctx.last_actions - 3)
        for i = start_idx, #ctx.last_actions do
            table.insert(actions_list, ctx.last_actions[i].summary or ctx.last_actions[i].command or "unknown action")
        end
        recent_actions = table.concat(actions_list, " | ")
    end

    logger.info("[OPTIMIZER] Generating smart continuation prompt...")

    -- 2. Build prompt
    local prompt = string.format([[
You are a Continuation Prompt Generator. Analyze the current conversation state and generate a concise follow-up message to guide the main agent.

TASK SUMMARY: %s
CURRENT PLAN: %s
RECENT ACTIONS: %s
LAST ASSISTANT MESSAGE: %s

Generate a single concise message (1-3 sentences) that:
1. Acknowledges the current state
2. Asks a specific question or gives a clear direction
3. Helps the agent continue productively

Output ONLY the message text, nothing else.
]], task_summary, plan_text, recent_actions, last_assistant)

    local messages = {
        { role = "system", content = "You are a Continuation Prompt Generator. Output ONLY the concise follow-up message." },
        { role = "user", content = prompt }
    }

    -- 3. Non-streaming call to optimizer model with timeout
    M._last_llm_call_time = os.time()
    local res, err = llm_handler.send_request(opt_agent, messages, { override_params = { stream = false, temperature = 0.3, max_tokens = 256, stream_timeout = 30 } })
    if not res then
        logger.warn("[OPTIMIZER] Failed to generate continuation prompt: " .. tostring(err))
        return nil
    end

    local content = llm_handler.extract_content(res)
    if not content then
        logger.warn("[OPTIMIZER] No content in continuation prompt response.")
        return nil
    end

    -- 4. Clean up
    local continuation = utils.trim(content:gsub("`+", ""))

    if #continuation > 0 then
        logger.info("[OPTIMIZER] Generated continuation prompt: " .. continuation:sub(1, 80) .. "...")
        return continuation
    else
        logger.warn("[OPTIMIZER] Empty continuation prompt returned.")
        return nil
    end
end
-- ============================================================================
-- LLM-POWERED SUMMARIZATION (Step 3)
-- ============================================================================
-- Summary cache to avoid re-summarizing the same content
M._summary_cache = {}
M._summary_cache_max = 100
M._llm_summarization_count = 0
M._llm_summarization_reset_time = 0
M._MAX_SUMMARIES_PER_TURN = 3
M._MIN_MESSAGE_LENGTH = 5000
-- Reset summarization counter periodically
local function _reset_summarization_counter()
    local now = os.time()
    if now - M._llm_summarization_reset_time > 60 then  -- Reset every minute
        M._llm_summarization_count = 0
        M._llm_summarization_reset_time = now
    end
end
-- Heuristic: determine if LLM summarization is beneficial
function M.should_summarize_with_llm(msg, config)
    if not msg or not msg.content then return false end
    local llm_cfg = (config and config.COMPRESSION and config.COMPRESSION.llm_summarization) or {}
    if not llm_cfg.enabled then return false end
    local min_len = llm_cfg.min_message_length or M._MIN_MESSAGE_LENGTH
    local max_per_turn = llm_cfg.max_summaries_per_turn or M._MAX_SUMMARIES_PER_TURN
    -- Skip short messages
    if #msg.content < min_len then return false end
    -- Skip if we've hit the per-turn limit
    _reset_summarization_counter()
    if M._llm_summarization_count >= max_per_turn then return false end
    -- Only summarize messages containing reasoning/thinking
    if not msg.content:match("<thinking>") and not msg.content:match("reasoning") and
       not msg.content:match("analysis") and not msg.content:match("consider") then
        return false
    end
    -- Skip messages with commands (they need to stay intact)
    if msg.content:match("||| COMMAND |||") then return false end
    return true
end
-- Summarize a single message using the optimizer LLM
function M.summarize_message(msg, config)
    local opt_agent = config and config.OPTIMIZER_AGENT
    if not opt_agent then 
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return nil 
    end
    if not msg or not msg.content or #msg.content == 0 then return nil end
    -- Check cache first
    local content_hash = string.format("%x", #msg.content) .. "_" .. string.sub(msg.content, 1, 50)
    if M._summary_cache[content_hash] then
        logger.info("[OPTIMIZER] Using cached summary for message.")
        return M._summary_cache[content_hash]
    end
    -- Rate limiting
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
    -- Truncate input if too long for the LLM
    local max_input = 8000
    local truncated_content = msg.content
    if #msg.content > max_input then
        -- Keep beginning and end, omit middle
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
        -- Cache the summary
        if #M._summary_cache >= M._summary_cache_max then
            -- Evict oldest entry
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
-- Summarize a segment of conversation
function M.summarize_conversation_segment(messages, max_tokens, config)
    if not messages or #messages == 0 then return "" end
    local opt_agent = config and config.OPTIMIZER_AGENT
    if not opt_agent then 
        logger.warn("[OPTIMIZER] SKIPPED: config.OPTIMIZER_AGENT is not defined.")
        return ""
    end
    -- Rate limiting
    local now = os.time()
    local rate_limit = (config and config.COMPRESSION and config.COMPRESSION.llm_summarization and config.COMPRESSION.llm_summarization.rate_limit_seconds) or 30
    if now - M._last_llm_call_time < rate_limit then
        logger.info("[OPTIMIZER] SKIPPED: Rate limited for segment summarization.")
        return ""
    end
    logger.info("[OPTIMIZER] Summarizing conversation segment with LLM...")
    -- Build a compact representation of the messages
    local compact_msgs = {}
    local total_len = 0
    local max_total = 10000
    for i, msg in ipairs(messages) do
        if msg and msg.content then
            local role = msg.role or "unknown"
            local content = msg.content
            -- Truncate individual messages if needed
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