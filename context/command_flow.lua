-- context/command_flow.lua
-- Command flow processing extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local utils = require("utils")
local registry = require("tool_registry")
local history = require("context.history")
-- ============================================================================
-- VALIDATE TOOL RESPONSE (helper)
-- ============================================================================
local function _validate_tool_response(res)
    if type(res) ~= "table" then
        return false, "Tool response is not a table (got " .. type(res) .. ")"
    end
    if res.output ~= nil and type(res.output) ~= "string" then
        return false, "Tool output must be a string, got: " .. type(res.output)
    end
    if res.signal ~= nil and type(res.signal) ~= "string" then
        return false, "Tool signal must be a string, got: " .. type(res.signal)
    end
    return true, nil
end
-- ============================================================================
-- NORMALIZE COMMAND (helper)
-- ============================================================================
local function _normalize_cmd(cmd)
    if not cmd then return "" end
    return cmd:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
end
-- ============================================================================
-- PROCESS TURN RESPONSE
-- ============================================================================
function M.process_turn_response(ctx, agent_name, raw_content, executor)
    local cmd, parse_err = executor:parse_command(raw_content)
    -- 1. No command -> conversation
    if not cmd then
        history.add_message(ctx, agent_name, "assistant", utils.trim(raw_content))
        return { type = "CONVERSATION", hint = parse_err }
    end
    -- 2. Validation
    local valid, val_err = executor:validate_command(cmd)
    if not valid then
        ctx.consecutive_recoveries = (ctx.consecutive_recoveries or 0) + 1
        if ctx.consecutive_recoveries >= ctx.flow_config.command_flow.max_retries then
            return { type = "ERROR", message = "Validation failed after " .. ctx.flow_config.command_flow.max_retries .. " attempts." }
        end
        return { type = "RETRY", message = string.format("Command rejected: %s. Output exactly one valid command.", val_err) }
    end
    -- 2.5. Deduplication check: block duplicate commands
    if history.is_duplicate_command(ctx, cmd) then
        -- Find the previous output of this command from history so the model can see the result
        local prev_output = ""
        local hist = history.get_history(ctx, agent_name)
        -- Search backwards through history for the last user message that contains output from this command
        local tool_name = cmd:match("^([^:]+)")
        for j = #hist, 1, -1 do
            local msg = hist[j]
            if msg.role == "user" and msg.content and #msg.content > 10 then
                -- Look for tool output markers that match the command
                if tool_name then
                    if msg.content:match("%[" .. tool_name:upper() .. "%]") or
                       msg.content:match("%[OUTPUT%]") or
                       msg.content:match("%[RESULT%]") or
                       msg.content:match("^%[SEARCH") or
                       msg.content:match("^%[SYSTEM") then
                        prev_output = msg.content
                        break
                    end
                else
                    prev_output = msg.content
                    break
                end
            end
        end
        local prev_output_section = ""
        if prev_output and #prev_output > 0 then
            -- Truncate if too long
            if #prev_output > 4096 then
                prev_output = prev_output:sub(1, 4096) .. "\n...(truncated)"
            end
            prev_output_section = "\n\n--- PREVIOUS OUTPUT (this command was already executed) ---\n" .. prev_output .. "\n--- END PREVIOUS OUTPUT ---"
        end
        local dup_msg = string.format(
            "[SYSTEM: DUPLICATE COMMAND BLOCKED] You already executed this command recently:\n||| COMMAND |||\n%s\n||| END_COMMAND |||%s\nPlease proceed to the next step or issue a different command.",
            cmd,
            prev_output_section
        )
        history.add_message(ctx, agent_name, "user", dup_msg)
        return { type = "DUPLICATE", message = dup_msg }
    end
    -- 2.6. Circuit breaker check: block tools in cooldown
    local cb_config = ctx.config and ctx.config.CIRCUIT_BREAKER
    if cb_config and cb_config.enabled then
        ctx.circuit_breaker_state = ctx.circuit_breaker_state or {}
        local tool_name_cb = cmd:match("^([^:]+)")
        if tool_name_cb then
            local cb_entry = ctx.circuit_breaker_state[tool_name_cb]
            if cb_entry and cb_entry.triggered_turn then
                local cooldown_until = cb_entry.triggered_turn + cb_config.cooldown_turns
                if ctx.current_turn and ctx.current_turn < cooldown_until then
                    local remaining = cooldown_until - ctx.current_turn
                    local cb_msg = string.format(
                        "[SYSTEM: CIRCUIT BREAKER] Tool '%s' is in cooldown due to repeated failures. " ..
                        "Please wait %d turn(s) before retrying this tool. Try a different approach or tool.",
                        tool_name_cb, remaining
                    )
                    history.add_message(ctx, agent_name, "user", cb_msg)
                    return { type = "CIRCUIT_BREAKER", message = cb_msg }
                end
            end
        end
    end
    -- 3. Execution (wrapped in pcall for safety)
    local tool_name = cmd:match("^([^:]+)")
    local ok, res_or_err = pcall(function()
        return registry.execute(cmd, ctx, agent_name)
    end)
    if not ok then
        -- registry.execute threw an error — log it and return a safe error result
        local logger = require("logger")
        logger.error(string.format("[COMMAND_FLOW] registry.execute threw an error for tool '%s': %s",
            tool_name or "unknown", tostring(res_or_err)))
        history.add_message(ctx, agent_name, "user",
            string.format("[SYSTEM: TOOL ERROR] Tool '%s' encountered an internal error: %s",
                tool_name or "unknown", tostring(res_or_err)))
        return { type = "ERROR", message = "Tool execution failed: " .. tostring(res_or_err) }
    end
    local res = res_or_err
    -- Validate tool response schema
    local valid, val_err = _validate_tool_response(res)
    if not valid then
        local logger = require("logger")
        logger.error(string.format("[COMMAND_FLOW] Invalid tool response from '%s': %s",
            tool_name or "unknown", val_err))
        history.add_message(ctx, agent_name, "user",
            string.format("[SYSTEM: TOOL ERROR] Tool '%s' returned invalid response: %s",
                tool_name or "unknown", val_err))
        return { type = "ERROR", message = "Invalid tool response: " .. val_err }
    end
    -- Save assistant response (trimmed if there was a command)
    local hist_content = raw_content
    if cmd:match("||| COMMAND |||") then
        local idx = raw_content:find("||| COMMAND |||")
        hist_content = raw_content:sub(1, idx - 1)
    end
    local trimmed_hist = utils.trim(hist_content)
    if trimmed_hist ~= "" then
        history.add_message(ctx, agent_name, "assistant", trimmed_hist)
    end
    -- If response was only a command, add system marker to preserve role alternation
    if trimmed_hist == "" and cmd then
        history.add_message(ctx, agent_name, "assistant", "[SYSTEM: Executing command without additional reasoning]")
    end
    if ctx.flow_config.command_flow.auto_squash_on_mutation then
        history.squash_last_mutation(ctx, agent_name)
    end
    -- Record this command as executed for dedup purposes
    history.add_executed_command(ctx, cmd)
    -- 3.5. Circuit breaker: track failures and successes
    if cb_config and cb_config.enabled and tool_name then
        local is_failure = false
        -- Only check signal for failure indicators (avoid false positives from output content)
        if res.signal and (res.signal == "ERROR" or res.signal == "FAILURE") then
            is_failure = true
        end
        local cb_entry = ctx.circuit_breaker_state[tool_name] or { failures = 0, triggered_turn = nil }
        if is_failure then
            cb_entry.failures = (cb_entry.failures or 0) + 1
            -- Trigger circuit breaker if threshold reached
            if cb_entry.failures >= cb_config.threshold then
                cb_entry.triggered_turn = ctx.current_turn
                ctx.circuit_breaker_state[tool_name] = cb_entry
                -- Inject warning message if configured
                if cb_config.warning_message then
                    local warn_msg = string.format(
                        "[SYSTEM: CIRCUIT BREAKER TRIGGERED] Tool '%s' has failed %d consecutive times. " ..
                        "It will be blocked for %d turns. Consider alternative approaches.",
                        tool_name, cb_entry.failures, cb_config.cooldown_turns
                    )
                    history.add_message(ctx, agent_name, "user", warn_msg)
                end
            else
                ctx.circuit_breaker_state[tool_name] = cb_entry
            end
        else
            -- Success: reset failure counter
            cb_entry.failures = 0
            cb_entry.triggered_turn = nil
            ctx.circuit_breaker_state[tool_name] = cb_entry
        end
    end
    -- Add result to history as user/system
    if res.output then
        local sanitized_output = utils.sanitize_for_json(res.output)
        history.add_message(ctx, agent_name, "user", sanitized_output)
    end
    return { type = res.signal == "PIPELINE_NEXT_STAGE" and "COMPLETED" or "EXECUTED",
             tool = tool_name, output = res.output, signal = res.signal }
end
return M