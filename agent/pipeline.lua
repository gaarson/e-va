local status_server = require("status_server")
local ui = require("ui")
local strings = require("utils.strings")
local M = {}
--- Executes the pipeline: iterates through stages, handles interactive/parallel/sequential modes,
--- handoff logic, and loop-back mechanism.
-- @param ctx: ContextFlow instance
-- @param config: Configuration table
-- @param logger: Logger instance
-- @param run_agent_turn_fn: Function reference to run_agent_turn (from turn module)
-- @param state_file: Path to state file for saving
function M.execute_pipeline(ctx, config, logger, run_agent_turn_fn, state_file)
    local turn = 1
    local MAX_TURNS = (config.PIPELINE_SETTINGS and config.PIPELINE_SETTINGS.MAX_TURNS) or 150
    local current_stage_idx = 1
    local last_active_agent = nil

    -- Helper: save state (atomic write via temp file + rename)
    local function save_state()
        local snap = ctx:snapshot()
        if not snap then return end
        local dir = state_file:match("(.*[/\\])")
        if dir then
            os.execute(string.format("mkdir -p '%s'", dir))
        end
        local tmp_file = state_file .. ".tmp"
        local ok, err = pcall(function()
            local f = io.open(tmp_file, "w")
            if not f then error("Cannot open temp file: " .. tostring(err)) end
            f:write(snap)
            f:close()
            -- Atomic rename
            os.rename(tmp_file, state_file)
        end)
        if not ok then
            logger.error(string.format("[STATE SAVE FAILED] %s", tostring(err)))
            -- Clean up temp file on failure
            os.execute(string.format("rm -f '%s'", tmp_file))
        end
    end

    while current_stage_idx <= #config.PIPELINE and turn < MAX_TURNS do
        local stage = config.PIPELINE[current_stage_idx]
        logger.info(string.format("\n=== PIPELINE STAGE [%d/%d]: %s ===", current_stage_idx, #config.PIPELINE, tostring(stage.stage)))
        status_server.update_status({
            agent_name = last_active_agent or "unknown",
            current_turn = turn,
            current_stage = tostring(stage.stage),
            stage_index = current_stage_idx,
            total_stages = #config.PIPELINE,
            state = "running"
        })
        ui.print_stage_header(current_stage_idx, #config.PIPELINE, tostring(stage.stage))

        local stage_complete = false

        -- Clear local history for new stage (but not knowledge base)
        for name, _ in pairs(ctx.history) do
            -- ctx.history[name] = {}
            -- If this is not a system agent/base, we can think about clearing,
            -- but simpler to just track that we don't copy previous stage history to current.
        end

        while not stage_complete and turn < MAX_TURNS do
            turn = turn + 1

            if stage.mode == "interactive" then
                local target_agent = "ARCHITECT"
                last_active_agent = target_agent
                if type(stage.agent) == "string" then target_agent = stage.agent
                elseif type(stage.agents) == "table" and type(stage.agents[1]) == "string" then target_agent = stage.agents[1]
                elseif type(stage.agents) == "string" then target_agent = stage.agents end

                logger.info(string.format("[INTERACTIVE MODE] Hooked to agent: %s", target_agent))
                ui.pipeline_ui.start_hitl_session(target_agent)
                while true do
                    local user_input = ui.pipeline_ui.get_user_input(target_agent)
                    if not user_input or strings.trim(user_input) == "" or strings.trim(user_input) == "/exit" then
                        ui.print_error("User aborted the execution.")
                        os.exit(0)
                    end
                    -- Handle control commands via centralized parser
                    local cmd = ui.pipeline_ui.parse_command(user_input, config)
                    if cmd.action == "NEXT_STAGE" then
                        ui.print_success(cmd.message)
                        stage_complete = true
                        break
                    elseif cmd.action == "PREV_STAGE" then
                        if current_stage_idx > 1 then
                            ui.print_success(cmd.message)
                            current_stage_idx = current_stage_idx - 1
                            stage_complete = true
                            break
                        else
                            ui.print_warning("Cannot go back further.")
                        end
                    elseif cmd.action == "SWITCH_STAGE" then
                        ui.print_success(cmd.message)
                        current_stage_idx = cmd.target_idx
                        stage_complete = true
                        break
                    elseif cmd.action == "STATUS" then
                        local status_info = string.format("Turn: %d | Stage: %d/%d (%s) | Agent: %s",
                            turn, current_stage_idx, #config.PIPELINE,
                            tostring(stage.stage), last_active_agent or "none")
                        ui.printer.banner("[STATUS]", ui.colors.blue)
                        ui.printer.line("  " .. status_info)
                        ui.printer.line("")
                    elseif cmd.action == "HELP" then
                        ui.pipeline_ui.print_help()
                    elseif cmd.action == "ABORT" then
                        ui.print_error(cmd.message or "User aborted the execution.")
                        os.exit(0)
                    elseif cmd.action == "SKIP" then
                        -- Empty input, just continue the loop
                    elseif cmd.action == "ERROR" then
                        ui.print_error(cmd.message)
                    elseif cmd.action == "MESSAGE" and strings.trim(user_input) ~= "" then
                        ctx:add_message(target_agent, "user", user_input)
                        local sig = run_agent_turn_fn(target_agent, config.AGENTS[target_agent], turn, ctx, config, save_state)
                        local auto_loop_count = 0
                        local MAX_AUTO_LOOP = 420
                        -- Auto-loop: keep running agent while it executes commands (AUTO_LOOP signal)
                        while sig == "AUTO_LOOP" and auto_loop_count < MAX_AUTO_LOOP do
                            auto_loop_count = auto_loop_count + 1
                            turn = turn + 1
                            logger.info(string.format("[AUTO-LOOP %d/%d] Agent continuing execution...", auto_loop_count, MAX_AUTO_LOOP))
                            if auto_loop_count % 10 == 0 then
                                ui.printer.auto_loop_message(auto_loop_count, target_agent)
                            end
                            sig = run_agent_turn_fn(target_agent, config.AGENTS[target_agent], turn, ctx, config, save_state)
                        end

                        if auto_loop_count >= MAX_AUTO_LOOP then
                            ui.print_warning("Auto-loop limit (" .. MAX_AUTO_LOOP .. ") reached. Resuming user input.")
                        end
                        if sig == "PIPELINE_NEXT_STAGE" then
                            ui.print_warning("Agent requested next stage. Type '/go' to proceed.")
                        elseif sig == "ERROR" then
                            -- ERROR: LLM failed (including empty response exhaustion).
                            -- Remove the user message we just added so it doesn't get lost, and prompt again.
                            ctx:drop_last_message(target_agent)
                            ui.print_error("Received empty/error response from LLM. Your message was not consumed. Please try again.")
                            -- Do NOT increment turn, loop back to io.read()
                        elseif sig == nil then
                            -- CONVERSATION (nil): normal chat response, no command executed
                            turn = turn + 1
                        end
                        -- AUTO_LOOP already handled above
                    end
                    io.write("\n")
                end
            elseif stage.mode == "parallel" then
                local threads = {}
                for _, a_name in ipairs(stage.agents or {}) do
                    local agent_name = tostring(a_name)
                    last_active_agent = agent_name
                    local co = coroutine.create(function()
                        return run_agent_turn_fn(agent_name, config.AGENTS[agent_name], turn, ctx, config, save_state)
                    end)
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
                -- Sequential mode
                for _, a_name in ipairs(stage.agents or {}) do
                    local agent_name = tostring(a_name)
                    last_active_agent = agent_name
                    local sig = run_agent_turn_fn(agent_name, config.AGENTS[agent_name], turn, ctx, config, save_state)
                    if sig == "PIPELINE_NEXT_STAGE" then
                        stage_complete = true
                        break
                    end
                end
            end
        end
        if turn >= MAX_TURNS then
            status_server.update_status({state = "aborted"})
            ui.print_fatal_block({ Error = "Max turns reached", Turns = tostring(MAX_TURNS) })
            os.exit(1)
        end
        if stage_complete then
            -- Handoff logic before stage transition
            if config.HANDOFF and config.HANDOFF.enabled and last_active_agent then
                local agent_cfg = config.AGENTS[last_active_agent]
                local memo = ctx:generate_handoff_memo(last_active_agent, agent_cfg)
                ctx:set_handoff_memo(memo)
                ctx:clear_history_for_stage(config.HANDOFF.clear_history)
                ui.printer.highlight(string.format("[HANDOFF] Generated memo for agent '%s'. Strategy: %s", last_active_agent, config.HANDOFF.clear_history), ui.colors.cyan)

                -- Load files from plan
                if config.HANDOFF.auto_load_plan_files then
                    ctx:get_handoff_files()
                end

                -- Inject files into context of next stage
                if config.HANDOFF.pass_knowledge_base or config.HANDOFF.pass_pinned_files or config.HANDOFF.pass_requested_files then
                    local next_agent = config.PIPELINE[current_stage_idx + 1] and config.PIPELINE[current_stage_idx + 1].agents[1] or "CODER"
                    ctx:inject_handoff_files(next_agent)
                    -- NOTE: Removed auto-pin loop here. Handoff files are already injected into
                    -- the receiving agent's history as <file_context> blocks. Pinning them additionally
                    -- would cause them to be re-injected via the recency block every turn, creating duplication.
                    -- The recency-aware deduplication in builder.lua handles this correctly.
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
    status_server.update_status({state = "finished"})
    ui.print_success("Pipeline execution finished entirely.")
    os.remove(state_file)
end

return M
