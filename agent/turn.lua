local utils = require("utils")
local socket = require("socket")
local json = require("JSON")
local ui = require("ui")
local llm = require("llm_handler")
local logger = require("logger")
local status_server = require("status_server")
local context_optimizer = require("context_optimizer")
local optimizer = require("optimizer")
local multi_stage_executor = require("multi_stage_executor")
local multi_stage = require("agent.multi_stage")
local tool_registry = require("tool_registry")
local command_executor = require("command_executor")

local M = {}

--- Runs a single agent turn: syncs files, builds context, sends LLM request, handles retries/interruptions,
--- routes selective multi-stage tools, recovers from empty responses, and processes the result.
-- @param agent_name string
-- @param agent_cfg table
-- @param turn number
-- @param ctx ContextFlow instance
-- @param config table
-- @param save_state function
-- @return string|nil signal ("PIPELINE_NEXT_STAGE", "ERROR", "AUTO_LOOP", or nil)
function M.run_agent_turn(agent_name, agent_cfg, turn, ctx, config, save_state)
    -- Build deps table once for multi_stage calls
    local deps = {
        logger = logger,
        utils = utils,
        llm = llm,
        context_optimizer = context_optimizer,
        optimizer = optimizer,
        registry = tool_registry
    }
    ctx.consecutive_recoveries = 0
    local synced_files = ctx:sync_files()
    if #synced_files > 0 then
        logger.info(string.format("[FS WATCHER] Auto-synced %d changed file(s): %s", #synced_files, table.concat(synced_files, ", ")))
    end
    if turn >= 3 then ctx:clear_turn_requested_files() end

    if config.PICTURES_DIR then
        local t_img = socket.gettime()
        ctx:load_images(config.PROJECT_ROOT .. "/" .. config.PICTURES_DIR)
        local img_elapsed = socket.gettime() - t_img
        local img_count = ctx.images and #ctx.images or 0
        logger.info(string.format("[TURN DIAG] Image loading: %d images loaded, %.3fs elapsed", img_count, img_elapsed))
    end
    local executor = command_executor.new(ctx, agent_name)
    local limits = config.LIMITS
    local available_tokens = limits.MAX_CONTEXT - limits.RESERVED_OUTPUT - limits.SYSTEM_PROMPT_ESTIMATE
    local t_build = socket.gettime()
    local context_data = ctx:build_context(agent_name, agent_cfg, available_tokens)
    local build_elapsed = socket.gettime() - t_build
    local messages = context_data.messages
    local total_ctx_tokens = context_data.total_tokens
    logger.info(string.format("[TURN DIAG] build_context: %.3fs elapsed, tokens=%d", build_elapsed, total_ctx_tokens))
  
    --- LLOOGG TO FILE
    -- logger.log_context(turn, agent_name .. "_PROMPT", json:encode({
    --     turn = turn, agent = agent_name, tokens = total_ctx_tokens, payload = messages
    -- }))
    logger.info(string.format("[TURN %d] Agent: %s | Active Context Tokens: ~%d / %d", turn, tostring(agent_name), total_ctx_tokens, limits.MAX_CONTEXT))
    ui.print_turn_header(turn, tostring(agent_name), total_ctx_tokens, limits.MAX_CONTEXT)
    ui.print_ai_prompt(tostring(agent_name))
    local printer = utils.stream_token_printer(agent_cfg)
    local response_data, err
    status_server.add_log(string.format("Turn %d started for agent %s", turn, agent_name))
    local max_retries, retry_delay = 5, 5
    local interruption_retries, MAX_INTERRUPTION_RETRIES = 0, 3
    local signal = nil
    while true do
        logger.info(string.format('\n[STREAM] Sending request to model=%s, stream=true', agent_cfg.model))
        for attempt = 1, max_retries do
            response_data, err = llm.send_request(agent_cfg, messages, { on_token = printer })
            if response_data then break end
            if err == 'DUPLICATE_REQUEST_BLOCKED' then
                logger.warn(string.format("[DEDUP] Duplicate request blocked on attempt %d. Waiting %ds before retry...", attempt, retry_delay))
                socket.sleep(math.max(retry_delay, 5))
                retry_delay = retry_delay * 2
            elseif type(err) == 'table' and err.type == 'CONTEXT_EXCEEDED' then
                local new_val = context_optimizer.shrink_max_tokens(agent_cfg, config.AGENT_DEFAULTS.min_max_tokens or 1024)
                logger.info(string.format('[CONTEXT OPTIMIZATION] Reduced max_tokens to %d', new_val))
            else
                logger.warn(string.format("\n[NETWORK INCIDENT] LLM API Error (Attempt %d/%d): %s", attempt, max_retries, tostring(err)))
            end
            if attempt < max_retries then
                ui.printer.retry_message(attempt, max_retries, retry_delay)
                socket.sleep(retry_delay)
                retry_delay = retry_delay * 3
            end
        end
        if not response_data then break end
        if response_data.interrupted then
            interruption_retries = interruption_retries + 1
            if interruption_retries > MAX_INTERRUPTION_RETRIES then
                logger.warn("[INTERRUPT] Max interruption retries reached. Returning AUTO_LOOP to restart turn cleanly.")
                signal = "AUTO_LOOP"
                break
            end
            local had_input = ui.interrupt.handle_interruption_with_capture(agent_name)
            if had_input then
                -- User provided input; store it in history so next build_context picks it up
                ctx:add_message(agent_name, 'user', had_input)
                logger.info("[INTERRUPT] User input stored in history. Returning AUTO_LOOP to rebuild context fresh.")
                signal = "AUTO_LOOP"
                break
            else
                -- User pressed Enter with no input; just retry within same loop
                response_data = nil
            end
        else break end
    end

    utils.flush_stream_buffer(printer)
    if not response_data then
        -- FAILSAFE LOGGING: Enhanced diagnostics for network failures
        local diag_msg = string.format("FATAL: Network unreachable after %d attempts. Err=%s, URL=%s, Model=%s",
            max_retries, tostring(err or "nil"), agent_cfg.url or "UNSET", agent_cfg.model or "UNSET")
        logger.error(diag_msg)
        logger.error(diag_msg)
        status_server.add_log(string.format("Turn %d ERROR: Network unreachable for agent %s (URL=%s, Model=%s)",
            turn, agent_name, agent_cfg.url or "UNSET", agent_cfg.model or "UNSET"))
        -- Print colored [FATAL FAILURE] block
        ui.print_fatal_block({
            Agent = agent_name,
            Turn = tostring(turn),
            URL = agent_cfg.url or "UNSET",
            Model = agent_cfg.model or "UNSET",
            Error = tostring(err or "nil"),
            Troubleshooting = "1. Check LLM server, 2. Verify API key, 3. Check network, 4. Review logs"
        })
        return "ERROR"
    end
    -- Token usage tracking
    if response_data.usage and response_data.usage.total_tokens then
        status_server.update_status({tokens_used = response_data.usage.total_tokens})
    end

    -- 1. Extract response content FIRST
    local content = ""
    if response_data.choices and response_data.choices[1] and response_data.choices[1].message then
        content = response_data.choices[1].message.content
    end

    -- HANDLE TIMED-OUT RESPONSES
    if response_data.timed_out then
        logger.warn(string.format("[STREAM TIMEOUT] Partial response received (%d chars). Stream timed out but content is usable.", #(content or 0)))
        ui.print_warning(string.format("Stream timed out after %d chars of content. Response may be incomplete.", #(content or 0)))
    end

    -- SELECTIVE MULTI-STAGE ROUTING (Two-phase tool invocation)
    if agent_cfg.use_selective_multi_stage and agent_cfg.multi_stage_tools then
                local executor_parse = command_executor.new(ctx, agent_name)
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
                local file_path = nil
                local has_payload = false
                if tool_name == "patch" then
                    local args_part = parsed_cmd:match("^patch:%s*(.*)")
                    if args_part then
                        local first_line = args_part:match("^[^\r\n]+")
                        if first_line then
                            file_path = utils.trim(first_line)
                        end
                        -- Check if there's actual SEARCH/REPLACE content (not just a file path)
                        if args_part:find("<<<<<<< SEARCH") then
                            has_payload = true
                        end
                    end
                elseif tool_name == "create_file" then
                    local args_part = parsed_cmd:match("^create_file:%s*(.*)")
                    if args_part and utils.trim(args_part) ~= "" then
                        local first_line = args_part:match("^[^\r\n]+")
                        if first_line then
                            file_path = utils.trim(first_line)
                        end
                        -- Check if there's content after the file path
                        local rest = args_part:match("^[^\r\n]+\r?\n(.*)")
                        if rest and utils.trim(rest) ~= "" then
                            has_payload = true
                        end
                    end
                elseif tool_name == "delegate_plan" then
                    local args_part = parsed_cmd:match("^delegate_plan:%s*(.*)")
                    if args_part and utils.trim(args_part) ~= "" then
                        has_payload = true
                    end
                else
                    -- For other tools, any args after colon means payload exists
                    local args_part = parsed_cmd:match("^" .. tool_name .. ":%s*(.*)")
                    if args_part and utils.trim(args_part) ~= "" then
                        has_payload = true
                    end
                end
                local last_user_msg = nil
                local history = ctx.history[agent_name] or {}
                for i = #history, 1, -1 do
                    if history[i].role == "user" then
                        last_user_msg = history[i].content
                        break
                    end
                end
                last_user_msg = last_user_msg or ""
                local task_desc
                local payload_hint
                if has_payload then
                    -- Phase 2: Full command with payload - refine and re-execute
                    task_desc = string.format(
                        "Original command issued by the agent:\n" ..
                        "||| COMMAND |||\n%s\n||| END_COMMAND |||\n\n" ..
                        "Context from conversation:\n%s\n\n" ..
                        "Refine and re-execute this command. Preserve the tool choice and intent, but ensure the payload is correct and complete.",
                        parsed_cmd, last_user_msg
                    )
                    payload_hint = "Refine and execute the payload for this tool based on the task context. Use the original command as a starting point."
                else
                    -- Phase 1: Tool-only declaration - generate payload from scratch
                    task_desc = string.format(
                        "The agent has declared intent to use tool '%s'%s.\n\n" ..
                        "Context from conversation:\n%s\n\n" ..
                        "Generate the complete payload for this tool. Determine what needs to be done based on the conversation context and project state.",
                        tool_name,
                        file_path and string.format(" on file '%s'", file_path) or "",
                        last_user_msg
                    )
                    payload_hint = string.format(
                        "Generate a complete, valid payload for tool '%s'%s. " ..
                        "Analyze the conversation context to determine what changes are needed. " ..
                        "Ensure the payload is syntactically correct and addresses the current task.",
                        tool_name,
                        file_path and string.format(" targeting file '%s'", file_path) or ""
                    )
                end
                local success_criteria = string.format(
                    "Tool '%s' executes successfully without errors. The payload is syntactically valid and produces the expected result.",
                    tool_name
                )
                local multi_exec = multi_stage_executor.new(ctx, agent_name, {
                    max_iterations = agent_cfg.multi_stage_max_iterations or 3,
                    file_path = file_path
                })
                return multi_stage.run_multi_stage_loop(
                    multi_exec,
                    agent_name,
                    agent_cfg,
                    task_desc,
                    "SELECTIVE MULTI-STAGE",
                    true,
                    {
                        tool_name = tool_name,
                        payload_hint = payload_hint,
                        success_criteria = success_criteria,
                        file_path = file_path
                    },
                    ctx, config, deps
                )
            end
        end
    end

    -- HANDLE EMPTY RESPONSE: Strategy-pattern recovery
    if content == "" or utils.trim(content) == "" then
        logger.warn("[EMPTY RESPONSE] LLM returned empty content. Classifying failure and attempting targeted recovery...")
        local failure_reason = "UNKNOWN"
        local full_text = response_data and response_data.full_text or ""
        local full_reason = response_data and response_data.full_reason or ""
        local interrupted = response_data and response_data.interrupted or false

        if full_text == "" and full_reason == "" and not interrupted then
            failure_reason = "SERVER_DONE_IMMEDIATE"
            logger.warn("[FAILURE CLASSIFIER] Server sent [DONE] immediately without generating any tokens.")
        elseif err and type(err) == "table" and err.type == "CONTEXT_EXCEEDED" then
            failure_reason = "CONTEXT_OVERFLOW"
            logger.warn("[FAILURE CLASSIFIER] Context overflow detected.")
        elseif full_reason ~= "" and full_text == "" then
            failure_reason = "MODEL_REFUSAL"
            logger.warn("[FAILURE CLASSIFIER] Model generated reasoning but refused to produce output (possible safety filter).")
        elseif err and (err == "HTTP 408" or err == "HTTP 504" or err:match("timeout") or err:match("TIMEOUT")) then
            failure_reason = "NETWORK_TIMEOUT"
            logger.warn("[FAILURE CLASSIFIER] Network timeout detected.")
        elseif interrupted then
            failure_reason = "USER_INTERRUPT"
            logger.warn("[FAILURE CLASSIFIER] Generation was interrupted by user.")
        end

        logger.info(string.format("[FAILURE CLASSIFIER] Classified as: %s", failure_reason))

        local recovered_content, recovered_messages, recovered_err = multi_stage.recover_from_empty_response(
            ctx, agent_name, agent_cfg, config, messages, err, response_data, failure_reason, deps
        )

        if not recovered_content or utils.trim(recovered_content) == "" then
            logger.error(string.format("[EMPTY RESPONSE] Failed after recovery attempts (reason: %s). Giving up.", failure_reason))
            ui.print_error(string.format("LLM consistently returning empty responses (classified: %s). Please check your LLM server.", failure_reason))
            return "ERROR"
        end

        content = recovered_content
        messages = recovered_messages
        err = recovered_err
    end

    -- 2. Process turn response
    local result = ctx:process_turn_response(agent_name, content, executor)
    -- Log key events
    if result.type == "EXECUTED" then
        status_server.add_log(string.format("Turn %d: Tool executed (%s)", turn, result.tool_name or "unknown"))
    elseif result.type == "ERROR" then
        status_server.add_log(string.format("Turn %d: Tool error - %s", turn, result.message or "unknown"))
    end

    -- PROACTIVE CONTEXT OPTIMIZATION
    if ctx:should_squash(agent_name) then
        optimizer.analyze_and_optimize(ctx, config)
        local last_res = optimizer.get_last_result()
        if last_res then
            logger.info(string.format("[OPTIMIZER] Last result: summary='%s', removed=%d, pinned=%d",
                last_res.new_summary or "N/A",
                #last_res.files_to_remove,
                #last_res.files_to_pin))
        end
    end

    -- 3. Handle result
    if result.type == "COMPLETED" then
        return "PIPELINE_NEXT_STAGE"
    elseif result.type == "ERROR" then
        logger.error("Agent execution error: " .. (result.message or "Unknown error"))
        return "ERROR"
    elseif result.type == "CIRCUIT_BREAKER" then
        logger.warn(string.format("[CIRCUIT BREAKER] Tool in cooldown. Message injected into history."))
        save_state()
        return "AUTO_LOOP"
    elseif result.type == "DUPLICATE" then
        logger.warn(string.format("[DEDUP] Blocked duplicate command. Message injected into history."))
        save_state()
        return "AUTO_LOOP"
    elseif result.type == "EXECUTED" then
        save_state()
        return "AUTO_LOOP"
    end

    save_state()

    -- Conversation
    return nil
end

return M