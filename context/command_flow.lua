-- context/command_flow.lua


-- Command flow processing extracted from context_flow.lua.

-- All functions take ctx (the context_flow instance) as the first argument.


local M = {}


local utils = require("utils")

local registry = require("tool_registry")

local history = require("context.history")



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

                    if msg.content:match("\[" .. tool_name:upper() .. "\]") or

                       msg.content:match("\[OUTPUT\]") or

                       msg.content:match("\[RESULT\]") or

                       msg.content:match("^\[SEARCH") or

                       msg.content:match("^\[SYSTEM") then

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


    -- 3. Execution

    local res = registry.execute(cmd, ctx, agent_name)

    local tool_name = cmd:match("^([^:]+)")


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


    -- Add result to history as user/system

    if res.output then

        local sanitized_output = utils.sanitize_for_json(res.output)

        history.add_message(ctx, agent_name, "user", sanitized_output)

    end


    return { type = res.signal == "PIPELINE_NEXT_STAGE" and "COMPLETED" or "EXECUTED",

             tool = tool_name, output = res.output, signal = res.signal }

end



return M