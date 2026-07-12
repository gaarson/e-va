local utils = require("utils")
local inspect = require('inspect')
local socket = require("socket")
local agent_home = os.getenv("AGENT_HOME") or "."
local project_root = os.getenv("PROJECT_ROOT") or "."

local config = assert(utils.load_config(agent_home .. "/config.lua"), "CRITICAL: Could not load base config.lua")
local local_config = utils.load_config(project_root .. "/.e-va-conf/config.lua")

if local_config then
    config = utils.deep_merge(config, local_config)
    print("\n\27[36m[SYSTEM INFO]: Applied local overrides from .e-va-conf/config.lua\27[0m")
    config = utils.apply_agent_defaults(config)
end

if type(config.PIPELINE) ~= "table" or #config.PIPELINE == 0 then
    print("\n\27[33m[SYSTEM WARNING]: Bypassing config file. Injecting memory-safe PIPELINE.\27[0m")
    config.PIPELINE = {
        { stage = "ANALYSIS_AND_PLANNING", agents = { "ARCHITECT" }, mode = "sequential" },
        { stage = "REVIEW_AND_CHAT", agents = { "ARCHITECT" }, mode = "interactive" },
        { stage = "IMPLEMENTATION", agents = { "CODER" }, mode = "sequential" }
    }
end
config = utils.apply_agent_defaults(config)

	local llm = require("llm_handler")
	local json = require("JSON")
	local context_optimizer = require("context_optimizer")
	local optimizer = require("optimizer")

local logger = require("logger")
local ContextFlow = require("context_flow")
local registry = require("tool_registry")
local tools = require("tools")
local os = require("os")
local multi_stage_executor = require("multi_stage_executor")

local ctx = ContextFlow.new(config.CONTEXT_FLOW, config)
local STATE_FILE = config.PROJECT_ROOT .. "/.e-va-conf/.state.json"

local function save_state()
    local snap = ctx:snapshot()
    if snap then
        os.execute(string.format("mkdir -p '%s/.e-va-conf'", config.PROJECT_ROOT))
        local f = io.open(STATE_FILE, "w")
        if f then f:write(snap); f:close() end
    end
end

local function resolve_task_instruction(task, config, utils, logger)
    local instruction = task.instruction
    if task.instruction_file then
        local instr_path = config.PROJECT_ROOT .. "/.e-va-conf/" .. task.instruction_file
        local file_content = utils.read_file_range(instr_path)
        if file_content then
            instruction = utils.trim(file_content)
            task.instruction = instruction
        else
            logger.error("IO_ERROR: Could not read instruction_file at " .. instr_path)
            return nil, "Missing instruction_file mapping"
        end
    end
    return instruction, nil
end
local restored = false

-- STEP 4: Prompt user if previous session state exists
local state_file_exists = utils.read_file_range(STATE_FILE) ~= nil
if state_file_exists then
    io.write("\n\27[33m[SYSTEM] Previous session found. Continue (y) or start new (n)?\27[0m ")
    io.flush()
    local user_choice = io.read("*l")
    if user_choice and (user_choice:lower() == "y" or user_choice:lower() == "yes") then
        local content = utils.read_file_range(STATE_FILE)
        if content and ctx:load_from_snapshot(content) then
            restored = true
            print("\n\27[32m[SYSTEM] Restored previous session.\27[0m")
        else
            print("\n\27[31m[SYSTEM] Failed to restore session. Starting fresh.\27[0m")
        end
    else
        -- User chose not to continue: delete state file and start fresh
        os.remove(STATE_FILE)
        print("\n\27[36m[SYSTEM] Discarded previous session. Starting fresh.\27[0m")
    end
end

tools.init(config)

local patcher_core = require("patcher_core")
if type(patcher_core.setup_sigint) == "function" then
    patcher_core.setup_sigint()
end

local custom_tools_path = config.PROJECT_ROOT .. "/.e-va-conf/custom_tools.lua"

local custom_tools_func = loadfile(custom_tools_path)
if custom_tools_func then
    local ok, err = pcall(function()
        local setup_tools = custom_tools_func()
        setup_tools(registry, utils, Context)
    end)
    if not ok then logger.error("Failed to load custom tools: " .. tostring(err)) end
end

local cli_args = {...}
local start_file = nil
local instruction = nil
local is_bootstrap = false
local target_agent = nil

local idx = 1
while idx <= #cli_args do
    local a = cli_args[idx]
    if type(a) == "string" then
        if a == "--bootstrap" then
            is_bootstrap = true
        elseif a == "--agent" and idx < #cli_args then
            target_agent = cli_args[idx+1]
            idx = idx + 1
        elseif not start_file then
            start_file = a
        elseif not instruction then
            instruction = a
        end
    end
    idx = idx + 1
end

if target_agent then
    if not config.AGENTS[target_agent] then
        print(string.format("\n\27[31m[FATAL] Agent '%s' not found in config.AGENTS\27[0m", target_agent))
        os.exit(1)
    end
    config.PIPELINE = {
        { stage = "DIRECT_EXECUTION", agents = { target_agent }, mode = "sequential" }
    }
    print(string.format("\n\27[36m[SYSTEM INFO]: Direct execution mode. Overriding pipeline for agent: %s\27[0m", target_agent))
end

if not instruction then
    local task_path = config.PROJECT_ROOT .. '/.e-va-conf/task.txt'
    local task_content = utils.read_file_range(task_path)
    if task_content and task_content ~= '' then
        instruction = utils.trim(task_content)
    end
end

-- Shared multi-stage loop function: handles the while-step loop for intent/generate/review/execute stages.
-- Used by both run_agent_turn_multi_stage and the selective multi-stage block in run_agent_turn.
-- HISTORY SAFETY: Uses deep copy of history for context building, never mutates persistent history.
-- @param multi_exec: The multi_stage_executor instance
-- @param agent_name: Name of the agent
-- @param agent_cfg: Agent configuration
-- @param last_user_msg: Last user message (used as task description)
-- @param label: Label for logging (default: "MULTI-STAGE")
-- @param skip_intent: If true, uses start_task_with_intent instead of start_task (for selective routing)
-- @param intent_params: Optional table with {tool_name, payload_hint, success_criteria} for skip_intent mode
local function _run_multi_stage_loop(multi_exec, agent_name, agent_cfg, last_user_msg, label, skip_intent, intent_params)
    label = label or "MULTI-STAGE"
    local history = ctx.history[agent_name] or {}
    local step
    if skip_intent and intent_params then
        -- Selective mode: skip INTENT phase, use pre-filled intent
        step = multi_exec:start_task_with_intent(
            last_user_msg,
            ctx.file_tree or "",
            intent_params.tool_name,
            intent_params.payload_hint,
            intent_params.success_criteria
        )
    else
        -- Normal mode: start with INTENT phase
        step = multi_exec:start_task(last_user_msg, ctx.file_tree or "")
    end
    while step.stage ~= "done" and step.stage ~= "error" do
        if step.stage == "intent" or step.stage == "generate" or step.stage == "review" then
            local limits = config.LIMITS
            local available_tokens = limits.MAX_CONTEXT - limits.RESERVED_OUTPUT - limits.SYSTEM_PROMPT_ESTIMATE
            -- Build DEEP COPY of history for safe manipulation
            local temp_history = {}
            for i, msg in ipairs(history) do
                temp_history[i] = { role = msg.role, content = msg.content }
            end
            -- Replace last user message with executor prompt for this round
            local original_msg = last_user_msg
            if temp_history[#temp_history] and temp_history[#temp_history].role == "user" then
                temp_history[#temp_history].content = step.prompt
            else
                table.insert(temp_history, { role = "user", content = step.prompt })
                original_msg = step.prompt
            end
            -- Build context from temporary history using pcall for safety
            local ok, context_data = pcall(function()
                local saved_history = ctx.history[agent_name]
                ctx.history[agent_name] = temp_history
                local result = ctx:build_context(agent_name, agent_cfg, available_tokens)
                ctx.history[agent_name] = saved_history  -- Restore immediately
                return result
            end)
            if not ok then
                logger.error(string.format("[%s] Context build failed: %s", label, tostring(context_data)))
                step = { stage = "error", message = "Context build failed: " .. tostring(context_data) }
                break
            end
            local messages = context_data.messages
            logger.info(string.format("[%s %s] Sending prompt to LLM...", label, step.stage))
            io.write(string.format("\n\27[35m>>> AI (%s) [%s]:\27[0m ", agent_name, step.stage))
            local printer = utils.stream_token_printer(agent_cfg)
            local response_data, err
            local max_retries, retry_delay = 5, 5
            response_data, err = llm.send_request(agent_cfg, messages, { on_token = printer })
            utils.flush_stream_buffer(printer)
            if not response_data then
                logger.error(string.format("[%s] FATAL: Network unreachable.", label), err)
                step = { stage = "error", message = "Network error" }
                break
            end
            local content = ""
            if response_data.choices and response_data.choices[1] and response_data.choices[1].message then
                content = response_data.choices[1].message.content
            end
            step = multi_exec:feed_response(content)
        elseif step.stage == "execute" then
            logger.info(string.format("[%s EXECUTE] Tool: %s", label, step.tool))
            -- Wrap execution in pcall + timeout for safety
            local execution_timeout = (agent_cfg.multi_stage_execution_timeout or 120) -- seconds
            local ok, res = pcall(function()
                -- Simple timeout wrapper using alarm/signal if available, otherwise just pcall
                local start_time = os.clock()
                local cmd = step.tool .. ":" .. step.payload
                local result = registry.execute(cmd, ctx, agent_name)
                -- Check if execution took too long (warning only, since we can't interrupt running code)
                local elapsed = os.clock() - start_time
                if elapsed > execution_timeout then
                    logger.warn(string.format("[%s EXECUTE] Tool '%s' took %.1fs (timeout threshold: %ds)", label, step.tool, elapsed, execution_timeout))
                end
                return result
            end)
            if not ok then
                logger.error(string.format("[%s EXECUTE] Tool execution failed: %s", label, tostring(res)))
                step = multi_exec:feed_execution_result("[EXECUTION ERROR]: " .. tostring(res))
            else
                step = multi_exec:feed_execution_result(res)
                if res.output then
                    ctx:add_message(agent_name, "user", utils.sanitize_for_json(res.output))
                end
            end
        end
    end
    if step.stage == "done" then
        logger.info(string.format("[%s] Task completed in %d iterations.", label, step.iterations))
        -- Inject completion message into agent history so the main agent knows the task is done
        local tool_name = multi_exec.intent and multi_exec.intent.TOOL or "unknown"
        ctx:add_message(agent_name, "system", string.format(
            "[MULTI-STAGE COMPLETED] Task finished successfully in %d iteration(s). The tool '%s' executed and was approved by review.",
            step.iterations, tool_name
        ))
        save_state()
        return "AUTO_LOOP"
    else
        logger.error(string.format("[%s] Error: %s", label, step.message))
        return "ERROR"
    end
end

-- Shared helper: sends an LLM request with retry/stream/recovery logic.
-- Used by both the main turn loop and the selective multi-stage loop.
-- Circuit breaker state: tracks consecutive tool failures
local function run_agent_turn(agent_name, agent_cfg, turn)
    ctx.consecutive_recoveries = 0
    -- Process pending optimizations from previous turn (non-blocking)
    optimizer.process_pending(ctx, config)
    local synced_files = ctx:sync_files()
    if #synced_files > 0 then
        logger.info(string.format("[FS WATCHER] Auto-synced %d changed file(s): %s", #synced_files, table.concat(synced_files, ", ")))
    end
    if turn >= 3 then ctx:clear_turn_requested_files() end

    if config.PICTURES_DIR then
        ctx:load_images(config.PROJECT_ROOT .. "/" .. config.PICTURES_DIR)
    end

    local executor = require("command_executor").new(ctx, agent_name)
    local limits = config.LIMITS
    local available_tokens = limits.MAX_CONTEXT - limits.RESERVED_OUTPUT - limits.SYSTEM_PROMPT_ESTIMATE

    local context_data = ctx:build_context(agent_name, agent_cfg, available_tokens)
    local messages = context_data.messages
    local total_ctx_tokens = context_data.total_tokens

    logger.log_context(turn, agent_name .. "_PROMPT", json:encode({
        turn = turn, agent = agent_name, tokens = total_ctx_tokens, payload = messages
    }))
    logger.info(string.format("[TURN %d] Agent: %s | Active Context Tokens: ~%d / %d", turn, tostring(agent_name), total_ctx_tokens, limits.MAX_CONTEXT))

    print(string.format("\n\27[90m[Turn %d | Agent: %s | Tokens: ~%d/%d]\27[0m", turn, tostring(agent_name), total_ctx_tokens, limits.MAX_CONTEXT))

    io.write(string.format("\n\27[35m>>> AI (%s):\27[0m ", tostring(agent_name)))
    local printer = utils.stream_token_printer(agent_cfg)
    local response_data, err
    local max_retries, retry_delay = 5, 5
    local interruption_retries, MAX_INTERRUPTION_RETRIES = 0, 3
    while true do
        logger.info(string.format('\n[STREAM] Sending request to model=%s, stream=true', agent_cfg.model))
        for attempt = 1, max_retries do
            response_data, err = llm.send_request(agent_cfg, messages, { on_token = printer })
            if response_data then break end
            if err == 'DUPLICATE_REQUEST_BLOCKED' then
                logger.warn(string.format("[DEDUP] Duplicate request blocked on attempt %d. Waiting %ds before retry...", attempt, retry_delay))
                -- Wait longer to allow the in-flight request to complete
                -- os.execute("sleep " .. tostring(math.max(retry_delay, 5)))
                socket.sleep(math.max(retry_delay, 5))
                retry_delay = retry_delay * 2
            elseif type(err) == 'table' and err.type == 'CONTEXT_EXCEEDED' then
                local new_val = context_optimizer.shrink_max_tokens(agent_cfg, config.AGENT_DEFAULTS.min_max_tokens or 1024)
                logger.info(string.format('[CONTEXT OPTIMIZATION] Reduced max_tokens to %d', new_val))
            else
                logger.warn(string.format("\n[NETWORK INCIDENT] LLM API Error (Attempt %d/%d): %s", attempt, max_retries, tostring(err)))
            end
            if attempt < max_retries then
                print(string.format("\n\27[33m[NETWORK RETRY %d/%d] Retrying in %d seconds...\27[0m", attempt, max_retries, retry_delay))
                -- os.execute("sleep " .. tostring(retry_delay))
                socket.sleep(retry_delay)
                retry_delay = retry_delay * 3
            end
        end
        if not response_data then break end
        if response_data.interrupted then
            logger.log_messages_pretty(messages, turn, agent_name, ctx)
            interruption_retries = interruption_retries + 1
            if interruption_retries > MAX_INTERRUPTION_RETRIES then break end
            print("\n\27[33m[SYSTEM] Generation interrupted. Provide additional context or corrections (or press Enter to continue):\27[0m")
            local user_input = io.read("*l")
            if user_input and user_input ~= "" then
                table.insert(messages, { role = "user", content = user_input })
            end
            response_data = nil
        else break end
    end

    utils.flush_stream_buffer(printer)
    if not response_data then
        logger.error("FATAL: Network unreachable after " .. max_retries .. " attempts.", err)
        return "ERROR"
    end

    -- 1. Extract response content FIRST (fix: was used before declaration on line 256)
    local content = ""
    if response_data.choices and response_data.choices[1] and response_data.choices[1].message then
        content = response_data.choices[1].message.content
    end


    -- HANDLE TIMED-OUT RESPONSES: If stream timed out but we got partial content,
    -- log it and treat as valid (the model was generating but network stalled)
    if response_data.timed_out then
        logger.warn(string.format("[STREAM TIMEOUT] Partial response received (%d chars). Stream timed out but content is usable.", #(content or 0)))
        print(string.format("\n\27[33m[WARNING] Stream timed out after %d chars of content. Response may be incomplete.\27[0m", #(content or 0)))
    end
    -- logger.info(string.format('[STREAM] Response received. Content length: %d, full_text length: %d', #(content or ''), #(response_data and response_data.full_text or '')))

    -- SELECTIVE MULTI-STAGE ROUTING: Parse tool name from command block and route if needed
    if agent_cfg.use_selective_multi_stage and agent_cfg.multi_stage_tools then
        local executor_parse = require("command_executor").new(ctx, agent_name)
        local parsed_cmd, _ = executor_parse:parse_command(content)
        if parsed_cmd then
            local tool_name = parsed_cmd:match("^([^:]+)") or parsed_cmd
            tool_name = utils.trim(tool_name)
            local is_multi_stage_tool = false
            for _, ms_tool in ipairs(agent_cfg.multi_stage_tools) do
                if tool_name == ms_tool then
                    is_multi_stage_tool = true
                    break
                end
            end
            if is_multi_stage_tool then
                logger.info(string.format("[SELECTIVE MULTI-STAGE] Routing tool '%s' through multi-stage executor", tool_name))
                -- Extract last user message for task context
                local last_user_msg = nil
                local history = ctx.history[agent_name] or {}
                for i = #history, 1, -1 do
                    if history[i].role == "user" then
                        last_user_msg = history[i].content
                        break
                    end
                end
                last_user_msg = last_user_msg or ""
                -- Build a rich task description that includes the original parsed command as a reference.
                local task_desc = string.format(
                    "Original command issued by the agent:\n" ..
                    "||| COMMAND |||\n%s\n||| END_COMMAND |||\n\n" ..
                    "Context from conversation:\n%s\n\n" ..
                    "Refine and re-execute this command. Preserve the tool choice and intent, but ensure the payload is correct and complete.",
                    parsed_cmd, last_user_msg
                )
                -- Derive success criteria from the tool name and command context
                local success_criteria = string.format(
                    "Tool '%s' executes successfully without errors. The payload is syntactically valid and produces the expected result.",
                    tool_name
                )
                -- Create multi-stage executor and use shared loop function
                local multi_exec = multi_stage_executor.new(ctx, agent_name, {
                    max_iterations = agent_cfg.multi_stage_max_iterations or 3
                })
                -- Use shared function with skip_intent=true to preserve the agent's original tool choice
                return _run_multi_stage_loop(
                    multi_exec,
                    agent_name,
                    agent_cfg,
                    task_desc,
                    "SELECTIVE MULTI-STAGE",
                    true,  -- skip_intent
                    {
                        tool_name = tool_name,
                        payload_hint = "Refine and execute the payload for this tool based on the task context. Use the original command as a starting point.",
                        success_criteria = success_criteria
                    }
                )
            end
        end
    end

    -- Handle empty response: ENHANCED RECOVERY with semantic failure classification
    if content == "" or utils.trim(content) == "" then
        logger.warn("[EMPTY RESPONSE] LLM returned empty content. Classifying failure and attempting targeted recovery...")
        -- =====================================================================
        -- FAILURE CLASSIFIER: Detect the root cause of empty response
        -- =====================================================================
        local failure_reason = "UNKNOWN"
        local full_text = response_data and response_data.full_text or ""
        local full_reason = response_data and response_data.full_reason or ""
        local interrupted = response_data and response_data.interrupted or false
        -- (a) Server-side immediate [DONE] — model produced zero tokens
        if full_text == "" and full_reason == "" and not interrupted then
            failure_reason = "SERVER_DONE_IMMEDIATE"
            logger.warn("[FAILURE CLASSIFIER] Server sent [DONE] immediately without generating any tokens.")
        -- (b) Context overflow — check if error indicates context exceeded
        elseif err and type(err) == "table" and err.type == "CONTEXT_EXCEEDED" then
            failure_reason = "CONTEXT_OVERFLOW"
            logger.warn("[FAILURE CLASSIFIER] Context overflow detected.")
        -- (c) Model refusal / safety filter — model generated reasoning but no text
        elseif full_reason ~= "" and full_text == "" then
            failure_reason = "MODEL_REFUSAL"
            logger.warn("[FAILURE CLASSIFIER] Model generated reasoning but refused to produce output (possible safety filter).")
        -- (d) Network timeout — stream timed out with no content
        elseif err and (err == "HTTP 408" or err == "HTTP 504" or err:match("timeout") or err:match("TIMEOUT")) then
            failure_reason = "NETWORK_TIMEOUT"
            logger.warn("[FAILURE CLASSIFIER] Network timeout detected.")
        -- (e) Interrupted by user — not really a failure, but handle gracefully
        elseif interrupted then
            failure_reason = "USER_INTERRUPT"
            logger.warn("[FAILURE CLASSIFIER] Generation was interrupted by user.")
        end
        logger.info(string.format("[FAILURE CLASSIFIER] Classified as: %s", failure_reason))
        -- =====================================================================
        -- TARGETED RECOVERY STRATEGIES based on classified failure reason
        -- =====================================================================
        local recovery_attempts = 0
        local MAX_RECOVERY_ATTEMPTS = 3
        -- Helper: extract content from response_data
        local function extract_content(rd)
            if rd and rd.choices and rd.choices[1] and rd.choices[1].message then
                return rd.choices[1].message.content
            end
            return ""
        end
        -- Helper: send request with exponential backoff
        local function send_with_retry(cfg, msgs, printer, base_delay)
            local rd, e
            rd, e = llm.send_request(cfg, msgs, { on_token = printer })
            if e == 'DUPLICATE_REQUEST_BLOCKED' then
                logger.warn("[EMPTY RESPONSE] Duplicate request blocked. Waiting " .. base_delay .. "s...")
                -- os.execute("sleep " .. tostring(base_delay))
                socket.sleep(base_delay)
                rd, e = llm.send_request(cfg, msgs, { on_token = printer })
            end
            return rd, e
        end
        -- ---- RECOVERY ATTEMPT 1: Context Overflow ----
        if failure_reason == "CONTEXT_OVERFLOW" then
            recovery_attempts = recovery_attempts + 1
            logger.info(string.format("[RECOVERY %d/%d] CONTEXT_OVERFLOW: Aggressively pruning history before retry...", recovery_attempts, MAX_RECOVERY_ATTEMPTS))
            -- Remove last 5 history messages to free up context
            local history = ctx.history[agent_name] or {}
            local removed_count = 0
            local max_remove = 5
            while removed_count < max_remove and #history > 3 do
                table.remove(history)
                removed_count = removed_count + 1
            end
            logger.info(string.format("[RECOVERY] Pruned %d messages from history.", removed_count))
            -- Also shrink max_tokens if possible
            local new_val = context_optimizer.shrink_max_tokens(agent_cfg, config.AGENT_DEFAULTS.min_max_tokens or 1024)
            logger.info(string.format("[RECOVERY] Reduced max_tokens to %d", new_val))
            -- Retry with reduced context
            local printer_r1 = utils.stream_token_printer(agent_cfg)
            response_data, err = send_with_retry(agent_cfg, messages, printer_r1, 3)
            content = extract_content(response_data)
        end
        -- ---- RECOVERY ATTEMPT 1: Model Refusal ----
        if failure_reason == "MODEL_REFUSAL" and (not content or utils.trim(content) == "") then
            recovery_attempts = recovery_attempts + 1
            logger.info(string.format("[RECOVERY %d/%d] MODEL_REFUSAL: Rephrasing last user message to avoid safety filter...", recovery_attempts, MAX_RECOVERY_ATTEMPTS))
            -- Rephrase the last user message to be less likely to trigger refusal
            if #messages >= 2 and messages[#messages].role == "user" then
                local original_msg = messages[#messages].content
                local rephrased = string.format(
                    "[SYSTEM: Rephrased for clarity]\n" ..
                    "Please assist with the following task. Provide a direct, practical response:\n\n%s",
                    original_msg
                )
                messages[#messages].content = rephrased
                logger.info("[RECOVERY] Rephrased last user message.")
            end
            local printer_r1 = utils.stream_token_printer(agent_cfg)
            response_data, err = send_with_retry(agent_cfg, messages, printer_r1, 2)
            content = extract_content(response_data)
        end
        -- ---- RECOVERY ATTEMPT 1: Network Timeout ----
        if failure_reason == "NETWORK_TIMEOUT" and (not content or utils.trim(content) == "") then
            recovery_attempts = recovery_attempts + 1
            logger.info(string.format("[RECOVERY %d/%d] NETWORK_TIMEOUT: Retrying with increased delay (10s)...", recovery_attempts, MAX_RECOVERY_ATTEMPTS))
            os.execute("sleep 10")
            local printer_r1 = utils.stream_token_printer(agent_cfg)
            response_data, err = send_with_retry(agent_cfg, messages, printer_r1, 10)
            content = extract_content(response_data)
        end
        -- ---- RECOVERY ATTEMPT 1: Server Done Immediate or Unknown ----
        if (failure_reason == "SERVER_DONE_IMMEDIATE" or failure_reason == "UNKNOWN") and (not content or utils.trim(content) == "") then
            recovery_attempts = recovery_attempts + 1
            logger.info(string.format("[RECOVERY %d/%d] %s: Blind retry with same messages (2s delay)...", recovery_attempts, MAX_RECOVERY_ATTEMPTS, failure_reason))
            os.execute("sleep 2")
            local printer_r1 = utils.stream_token_printer(agent_cfg)
            response_data, err = send_with_retry(agent_cfg, messages, printer_r1, 2)
            content = extract_content(response_data)
        end
        -- ---- RECOVERY ATTEMPT 2: Smart continuation via optimizer ----
        if (not content or utils.trim(content) == "") and recovery_attempts < MAX_RECOVERY_ATTEMPTS then
            recovery_attempts = recovery_attempts + 1
            logger.info(string.format("[RECOVERY %d/%d] Previous recovery failed. Generating smart continuation prompt...", recovery_attempts, MAX_RECOVERY_ATTEMPTS))
            local smart_prompt = optimizer.generate_continuation_prompt(ctx, config)
            if smart_prompt then
                logger.info("[SMART CONTINUATION] Using optimizer-generated prompt: " .. smart_prompt:sub(1, 80) .. "...")
                table.insert(messages, { role = "user", content = smart_prompt })
            else
                -- Fallback to static continuation prompt from config
                local fallback = (config.CONTEXT_FLOW and config.CONTEXT_FLOW.command_flow and config.CONTEXT_FLOW.command_flow.continuation_prompt) or "Please continue with the task."
                logger.info("[SMART CONTINUATION] Optimizer unavailable, using fallback: " .. fallback)
                table.insert(messages, { role = "user", content = fallback })
            end
            local printer_r2 = utils.stream_token_printer(agent_cfg)
            response_data, err = send_with_retry(agent_cfg, messages, printer_r2, 3)
            content = extract_content(response_data)
        end
        -- ---- RECOVERY ATTEMPT 3: Context reduction (remove last 5 history messages) ----
        if (not content or utils.trim(content) == "") and recovery_attempts < MAX_RECOVERY_ATTEMPTS then
            recovery_attempts = recovery_attempts + 1
            logger.info(string.format("[RECOVERY %d/%d] Final attempt: Reducing context by removing last 5 history messages...", recovery_attempts, MAX_RECOVERY_ATTEMPTS))
            local history = ctx.history[agent_name] or {}
            local removed_count = 0
            local max_remove = 5
            while removed_count < max_remove and #history > 3 do
                table.remove(history)
                removed_count = removed_count + 1
            end
            logger.info(string.format("[RECOVERY] Pruned %d additional messages from history.", removed_count))
            -- Also shrink max_tokens
            local new_val = context_optimizer.shrink_max_tokens(agent_cfg, config.AGENT_DEFAULTS.min_max_tokens or 1024)
            logger.info(string.format("[RECOVERY] Reduced max_tokens to %d", new_val))
            -- Rebuild messages with reduced context
            local limits = config.LIMITS
            local available_tokens = limits.MAX_CONTEXT - limits.RESERVED_OUTPUT - limits.SYSTEM_PROMPT_ESTIMATE
            local context_data = ctx:build_context(agent_name, agent_cfg, available_tokens)
            messages = context_data.messages
            local printer_r3 = utils.stream_token_printer(agent_cfg)
            response_data, err = send_with_retry(agent_cfg, messages, printer_r3, 5)
            content = extract_content(response_data)
        end
        -- =====================================================================
        -- FINAL CHECK: If still empty after all attempts, return error
        -- =====================================================================
        if not content or utils.trim(content) == "" then
            logger.error(string.format("[EMPTY RESPONSE] Failed after %d recovery attempts (reason: %s). Giving up.", recovery_attempts, failure_reason))
            print(string.format("\27[31m[SYSTEM] LLM consistently returning empty responses (classified: %s). Please check your LLM server.\27[0m", failure_reason))
            return "ERROR"
        end
        logger.info(string.format("[EMPTY RESPONSE] Recovery successful after %d attempt(s)!", recovery_attempts))
    end

    -- 2. Передаем ответ в новый модуль контекста
    -- process_turn_response сам выполнит команду, обновит историю и сделает squash если нужно
    local result = ctx:process_turn_response(agent_name, content, executor)

	    -- PROACTIVE CONTEXT OPTIMIZATION: If context is getting large, optimize before next turn
	    if ctx:should_squash(agent_name) then
	        optimizer.analyze_and_optimize(ctx, config)
	    end

	    -- 3. Обрабатываем результат
	    if result.type == "COMPLETED" then
	        return "PIPELINE_NEXT_STAGE" -- Сигнал для завершения стадии
	    elseif result.type == "ERROR" then
        logger.error("Agent execution error: " .. (result.message or "Unknown error"))
        return "ERROR"
    elseif result.type == "EXECUTED" then
        save_state()
        return "AUTO_LOOP"
    end
    save_state()

    -- Если это просто разговор
    return nil
end

local function execute_pipeline()
    local turn = 1
    local MAX_TURNS = (config.PIPELINE_SETTINGS and config.PIPELINE_SETTINGS.MAX_TURNS) or 150
    local current_stage_idx = 1
    local last_active_agent = nil

    while current_stage_idx <= #config.PIPELINE and turn < MAX_TURNS do
        local stage = config.PIPELINE[current_stage_idx]
        logger.info(string.format("\n=== PIPELINE STAGE [%d/%d]: %s ===", current_stage_idx, #config.PIPELINE, tostring(stage.stage)))
        print(string.format("\n\27[96m\27[1m=======================================================================\27[0m\n\27[93m [STAGE %d/%d] %s \27[0m\n\27[96m\27[1m=======================================================================\27[0m\n", current_stage_idx, #config.PIPELINE, tostring(stage.stage)))

        local stage_complete = false

        -- Очищаем локальную историю для новой стадии (но не базу знаний)
        -- Это соответствует требованию "с чистого листа, но с общей базой знаний"
        for name, _ in pairs(ctx.history) do
            -- ctx.history[name] = {}
            -- Если это не системный агент/база, можно подумать об очистке, 
            -- но проще просто следить, что мы не копируем историю предыдущей стадии в текущую.
        end

        while not stage_complete and turn < MAX_TURNS do
            turn = turn + 1

            if stage.mode == "interactive" then
                target_agent = "ARCHITECT"
                last_active_agent = target_agent
                if type(stage.agent) == "string" then target_agent = stage.agent
                elseif type(stage.agents) == "table" and type(stage.agents[1]) == "string" then target_agent = stage.agents[1]
                elseif type(stage.agents) == "string" then target_agent = stage.agents end

                logger.info(string.format("[INTERACTIVE MODE] Hooked to agent: %s", target_agent))
                io.write("\n\27[36m=== HUMAN-IN-THE-LOOP (HITL) SESSION ===\27[0m\n")
                io.write("Type your message. Commands: '/go' (next), '/back' (prev), '/mode <stage_name>', '/exit' (abort).\n")

                while true do
                    io.write(string.format("\n\27[36m>>> USER -> %s:\27[0m ", target_agent))
                    local user_input = io.read("*l")

                    if not user_input or user_input == "/exit" then
                        print("\n\27[31m[SYSTEM] User aborted the execution.\27[0m")
                        os.exit(0)
                    end

                    -- Обработка команд управления
                    if user_input == "/go" then
                        print("\n\27[32m[SYSTEM] Moving to the next pipeline stage...\27[0m")
                        -- current_stage_idx = current_stage_idx + 1
                        stage_complete = true
                        break
                    elseif user_input == "/back" then
                        if current_stage_idx > 1 then
                            print("\n\27[32m[SYSTEM] Moving back to previous stage...\27[0m")
                            current_stage_idx = current_stage_idx - 1
                            stage_complete = true
                            break
                        else
                            print("\n\27[33m[SYSTEM] Cannot go back further.\27[0m")
                        end
                    elseif user_input:match("^/mode%s*(%S+)") then
                        local mode_name = user_input:match("^/mode%s*(%S+)")
                        local found_idx = nil
                        for i, s in ipairs(config.PIPELINE) do
                            if s.stage == mode_name then
                                found_idx = i
                                break
                            end
                        end
                        if found_idx then
                            print(string.format("\n\27[32m[SYSTEM] Switching to stage: %s\27[0m", mode_name))
                            current_stage_idx = found_idx
                            stage_complete = true
                            break
                        else
                            print(string.format("\n\27[31m[SYSTEM] Stage '%s' not found in pipeline.\27[0m", mode_name))
                        end
                    elseif utils.trim(user_input) ~= "" then
                        ctx:add_message(target_agent, "user", user_input)
                        local sig = run_agent_turn(target_agent, config.AGENTS[target_agent], turn)
                        local auto_loop_count = 0
                        local MAX_AUTO_LOOP = 420
                        
                        -- Auto-loop: keep running agent while it executes commands (AUTO_LOOP signal)
                        while sig == "AUTO_LOOP" and auto_loop_count < MAX_AUTO_LOOP do
                            auto_loop_count = auto_loop_count + 1
                            turn = turn + 1
                            logger.info(string.format("[AUTO-LOOP %d/%d] Agent continuing execution...", auto_loop_count, MAX_AUTO_LOOP))

                            if auto_loop_count % 10 == 0 then

                                print(string.format("\n\27[90m[Auto-loop: %d iterations, Agent: %s]\27[0m", auto_loop_count, target_agent))

                            end
                            sig = run_agent_turn(target_agent, config.AGENTS[target_agent], turn)
                        end
                        
                        if auto_loop_count >= MAX_AUTO_LOOP then
                            print("\n\27[33m[SYSTEM] Auto-loop limit (" .. MAX_AUTO_LOOP .. ") reached. Resuming user input.\27[0m")
                        end
                        
                        if sig == "PIPELINE_NEXT_STAGE" then
                            print("\n\27[33m[SYSTEM] Agent requested next stage. Type '/go' to proceed.\27[0m")
                        elseif sig == "ERROR" then
                            -- ERROR: LLM failed (including empty response exhaustion). 
                            -- Remove the user message we just added so it doesn't get lost, and prompt again.
                            ctx:drop_last_message(target_agent)
                            print("\n\27[31m[SYSTEM] Received empty/error response from LLM. Your message was not consumed. Please try again.\27[0m")
                            -- Do NOT increment turn, loop back to io.read()
                        elseif sig == nil then
                            -- CONVERSATION (nil): normal chat response, no command executed
                            turn = turn + 1
                        end
                        -- AUTO_LOOP already handled above
                    end
                end
            elseif stage.mode == "parallel" then
                local threads = {}
                for _, a_name in ipairs(stage.agents or {}) do
                    local agent_name = tostring(a_name)
                    last_active_agent = agent_name
                    local co = coroutine.create(function() return run_agent_turn(agent_name, config.AGENTS[agent_name], turn) end)
                    table.insert(threads, { name = agent_name, co = co })
                end

                local active_threads = #threads
                while active_threads > 0 do
                    for _, th in ipairs(threads) do
                        if coroutine.status(th.co) ~= "dead" then
                            local ok, sig = coroutine.resume(th.co)
                            if sig == "PIPELINE_NEXT_STAGE" then
                                stage_complete = true; active_threads = 0; break
                            end
                        else
                            active_threads = active_threads - 1
                        end
                    end
                end
            else
                for _, a_name in ipairs(stage.agents or {}) do
                    local agent_name = tostring(a_name)
                    last_active_agent = agent_name
                    local sig = run_agent_turn(agent_name, config.AGENTS[agent_name], turn)
                    if sig == "PIPELINE_NEXT_STAGE" then
                        stage_complete = true
                        break
                    end
                end
            end
        end
        if turn >= MAX_TURNS then
            print("\n\27[31m[SYSTEM FATAL] Max turns reached. Aborting.\27[0m")
            os.exit(1)
        end
        if stage_complete then
            -- Handoff logic before stage transition
            if config.HANDOFF and config.HANDOFF.enabled and last_active_agent then
                local agent_cfg = config.AGENTS[last_active_agent]
                local memo = ctx:generate_handoff_memo(last_active_agent, agent_cfg)
                ctx:set_handoff_memo(memo)
                ctx:clear_history_for_stage(config.HANDOFF.clear_history)
                print(string.format("\n\27[36m[HANDOFF] Generated memo for agent '%s'. Strategy: %s\27[0m", last_active_agent, config.HANDOFF.clear_history))

                -- НОВЫЙ: Подгружаем файлы из плана
                if config.HANDOFF.auto_load_plan_files then
                    ctx:get_handoff_files()
                end

                -- НОВЫЙ: Инжектируем файлы в контекст следующего этапа
                if config.HANDOFF.pass_knowledge_base or config.HANDOFF.pass_pinned_files or config.HANDOFF.pass_requested_files then
                    local next_agent = config.PIPELINE[current_stage_idx + 1] and config.PIPELINE[current_stage_idx + 1].agents[1] or "CODER"
                    ctx:inject_handoff_files(next_agent)
                end
            end

            current_stage_idx = current_stage_idx + 1

            -- Loop-back mechanism: if we've exceeded the pipeline, search backwards for an interactive stage
            if current_stage_idx > #config.PIPELINE then
                local interactive_idx = nil
                for i = #config.PIPELINE, 1, -1 do
                    if config.PIPELINE[i].mode == "interactive" then
                        interactive_idx = i
                        break
                    end
                end

                if interactive_idx then
                    logger.info(string.format("[LOOP-BACK] Pipeline completed. Resuming at interactive stage #%d: %s", interactive_idx, config.PIPELINE[interactive_idx].stage))
                    current_stage_idx = interactive_idx
                else
                    logger.info("[PIPELINE] No interactive stage found. Terminating pipeline.")
                end
            end
        end
      end
    print("\n\27[32m[SYSTEM] Pipeline execution finished entirely.\27[0m")
    os.remove(STATE_FILE)
end

local function setup_and_run_task(task_file, task_instruction, max_turns)
    ctx:reset()

    local initial_msg = "TASK: " .. task_instruction
    local docs_loaded = {}

    ctx.file_tree = utils.explore_directory(config.PROJECT_ROOT, ".", 1)

    local readme_path = "README.md"
    local readme_content = utils.read_file_range(config.PROJECT_ROOT .. "/" .. readme_path)
    if readme_content then
        ctx:add_file(readme_path, readme_content)
        table.insert(docs_loaded, readme_path)
        initial_msg = initial_msg .. "\n\n<file_context path=\"" .. readme_path .. "\" status=\"PINNED\">\n" .. readme_content:gsub("\n", "\n\t") .. "\n</file_context>"
    end

    if ctx.file_tree then
        for line in ctx.file_tree:gmatch("[^\r\n]+") do
            local filepath = line:match("^(%S+)")
            if filepath and filepath:lower() ~= "readme.md" then
                if not filepath:find("/") and filepath:match("^[A-Z0-9_-]+%.[mM][dD]$") then
                    local content = utils.read_file_range(config.PROJECT_ROOT .. "/" .. filepath)
                    if content then
                        ctx:add_file(filepath, content)
                        ctx:pin_file(filepath)
                        table.insert(docs_loaded, filepath)
                    end
                end
            end
        end
    end

    if #docs_loaded > 0 then
        initial_msg = initial_msg .. "\n\n(Note: Auto-loaded core documentation: " .. table.concat(docs_loaded, ", ") .. ")"
    end

    if task_file then
        local norm_start = utils.normalize_path(config.PROJECT_ROOT, task_file)
        local content = utils.read_file_range(config.PROJECT_ROOT .. "/" .. norm_start)
        if content then
            ctx:add_file(norm_start, content)
            initial_msg = initial_msg .. "\n\n<file_context path=\"" .. norm_start .. "\" status=\"TARGET\">\n" .. content:gsub("\n", "\n\t") .. "\n</file_context>"
        end
    end

    local first_agent = "ARCHITECT"
    if type(config.PIPELINE) == "table" and config.PIPELINE[1] then
        local p_agents = config.PIPELINE[1].agents
        if type(p_agents) == "table" and #p_agents > 0 then
            first_agent = p_agents[1]
        elseif type(p_agents) == "string" then
            first_agent = p_agents
        end
    end

    ctx:add_message(first_agent, "user", initial_msg)

    local original_max = nil
    if config.PIPELINE_SETTINGS then
        original_max = config.PIPELINE_SETTINGS.MAX_TURNS
        if max_turns then config.PIPELINE_SETTINGS.MAX_TURNS = max_turns end
    end

    execute_pipeline()

    if config.PIPELINE_SETTINGS and original_max then
        config.PIPELINE_SETTINGS.MAX_TURNS = original_max
    end
end

local function run_pipe_mode()
    print("=== PIPE MODE START ===")
    io.flush()
    while true do
        io.stderr:write("> ")
        io.stderr:flush()
        local line = io.read("*l")
        if not line then break end
        local trimmed = line:gsub("^%s*(.-)%s*$", "%1")
        if trimmed == "quit" or trimmed == "exit" then
            print("=== PIPE MODE EXIT ===")
            break
        end
        if trimmed ~= "" then
            print("=== RESPONSE START ===")
            setup_and_run_task(nil, trimmed, nil)
            print("=== RESPONSE END ===")
            io.flush()
        end
    end
end

for _, a in ipairs(arg) do
    if a == "--pipe" then
        run_pipe_mode()
        os.exit(0)
    end
end

if not restored then
    if is_bootstrap then
      print("\n\27[35m[SYSTEM] Initializing Bootstrapper Meta-Agent with High Creativity...\27[0m")

        os.execute("mkdir -p " .. config.PROJECT_ROOT .. "/.e-va-conf/prompts")

        config.AGENTS = config.AGENTS or {}
        local arch_agent = config.AGENTS.ARCHITECT or {}

        -- Validate bootstrap prerequisites
        local has_url = arch_agent.url or os.getenv("LLM_URL")
        local has_model = arch_agent.model or os.getenv("LLM_MODEL")

        if not has_url then
            logger.error("[BOOTSTRAP] FATAL: No LLM URL found in config.AGENTS.ARCHITECT or env var LLM_URL.")
            print("\n\27[31m[FATAL] Cannot bootstrap: Missing LLM URL. Set config.AGENTS.ARCHITECT.url or export LLM_URL.\27[0m")
            os.exit(1)
        end

        if not has_model then
            logger.error("[BOOTSTRAP] FATAL: No LLM Model found in config.AGENTS.ARCHITECT or env var LLM_MODEL.")
            print("\n\27[31m[FATAL] Cannot bootstrap: Missing LLM Model. Set config.AGENTS.ARCHITECT.model or export LLM_MODEL.\27[0m")
            os.exit(1)
        end

        config.AGENTS.BOOTSTRAPPER = {
            name = "BOOTSTRAPPER",
            url = arch_agent.url or os.getenv("LLM_URL") or "http://127.0.0.1:8000/v1/chat/completions",
            model = arch_agent.model or os.getenv("LLM_MODEL") or "default-model",
            token = arch_agent.token or nil,
            params = {
                stream = true,
                temperature = 0.7,
                max_tokens = 8192,
            },
            prompt_file = "prompts/bootstrapper.md",
            allowed_tools = {"shell"}
        }

        config.PIPELINE = {
            { stage = "BOOTSTRAP_DISCOVERY", agents = { "BOOTSTRAPPER" }, mode = "interactive" }
        }

        ctx = ContextFlow.new(config.CONTEXT_FLOW, config)

        execute_pipeline()

    elseif instruction or target_agent then
        setup_and_run_task(start_file, instruction, nil)
    elseif ctx.config.TASKS and #ctx.config.TASKS > 0 then
        logger.info(string.format("Batch processing initiated. Found %d tasks.", #ctx.config.TASKS))
        for i, task in ipairs(ctx.config.TASKS) do
            local instr, err = resolve_task_instruction(task, config, utils, logger)
            if err then
                logger.error(err)
                instr = "FATAL_MISSING_FILE"
            end

            print(string.format("\n\27[35m=== STARTING TASK [%d/%d]: %s ===\27[0m", i, #ctx.config.TASKS, task.file or "Global Context"))

            local status, err = pcall(setup_and_run_task, task.file, instr, task.max_turns)

            if not status then
                logger.error("Task failed fatally: " .. tostring(err))
                if config.PIPELINE_SETTINGS and config.PIPELINE_SETTINGS.ABORT_ON_FATAL then
                    print("\n\27[31m[SYSTEM] Aborting batch execution due to fatal error in task " .. i .. "\27[0m")
                    os.exit(1)
                end
            end

            print(string.format("\n\27[32m=== FINISHED TASK [%d/%d] ===\27[0m", i, #ctx.config.TASKS))
        end
    else
        print("Usage: eva [file] \"<instruction>\" OR define TASKS in .e-va-conf/config.lua")
        os.exit(1)
    end
else
    execute_pipeline()
end
