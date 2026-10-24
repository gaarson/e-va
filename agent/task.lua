local ui = require('ui')
local command_parser = require("ui.command_parser")
local logger = require("logger")
local M = {}
--- Sets up and runs a task: builds initial context (file tree, README, docs, task file),
--- adds first message, and calls execute_pipeline.
-- @param task_file: Optional file path to target
-- @param task_instruction: Task instruction string
-- @param max_turns: Optional max turns override
-- @param ctx: ContextFlow instance
-- @param config: Configuration table
-- @param utils: Utils module
-- @param logger: Logger instance
-- @param execute_pipeline_fn: Function reference to execute_pipeline (from pipeline module)
-- @param run_agent_turn_fn: Function reference to run_agent_turn (from turn module)
-- @param state_file: Path to state file for saving
function M.setup_and_run_task(task_file, task_instruction, max_turns, ctx, config, utils, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
    ctx:reset()
    -- Handle nil task_instruction gracefully
    if not task_instruction or task_instruction == "" then
        task_instruction = "No task instruction provided. Please provide a task."
    end
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

    execute_pipeline_fn(ctx, config, logger, run_agent_turn_fn, state_file)
    if config.PIPELINE_SETTINGS and original_max then
        config.PIPELINE_SETTINGS.MAX_TURNS = original_max
    end
end

--- Runs pipe mode: reads from stdin, processes each line as a task.
-- @param ctx: ContextFlow instance
-- @param config: Configuration table
-- @param utils: Utils module
-- @param logger: Logger instance
-- @param execute_pipeline_fn: Function reference to execute_pipeline (from pipeline module)
-- @param run_agent_turn_fn: Function reference to run_agent_turn (from turn module)
-- @param state_file: Path to state file for saving
function M.run_pipe_mode(ctx, config, utils, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
    ui.printer.pipe_marker("=== PIPE MODE START ===")
    io.flush()
    while true do
        local line = ui.input.read_line("> ")
        if not line then break end
        local trimmed = line:gsub("^%s*(.-)%s*$", "%1")
        if trimmed == "quit" or trimmed == "exit" then
            ui.printer.pipe_marker("=== PIPE MODE EXIT ===")
            break
        end
        -- Multi-line input support: === MULTI-LINE START === ... === MULTI-LINE END ===
        if trimmed == "=== MULTI-LINE START ===" then
            local ml_lines = {}
            while true do
                local ml_line = ui.input.read_line("")
                if not ml_line then break end
                local ml_trimmed = ml_line:gsub("^%s*(.-)%s*$", "%1")
                if ml_trimmed == "=== MULTI-LINE END ===" then
                    break
                end
                table.insert(ml_lines, ml_line)
            end
            if #ml_lines > 0 then
                local multi_task = table.concat(ml_lines, "\n")
                ui.printer.pipe_marker("=== RESPONSE START ===")
                M.setup_and_run_task(nil, multi_task, nil, ctx, config, utils, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
                ui.printer.pipe_marker("=== RESPONSE END ===")
                io.flush()
            end
        elseif trimmed:match("^/") then
            local cmd = command_parser.parse(trimmed, config)
            if cmd.action == "MESSAGES" then
                for agent_name, _ in pairs(ctx.history) do
                    logger.log_final_dump(ctx, 0, agent_name, nil)
                end
                io.flush()
            elseif cmd.action == "STATUS" then
                ui.printer.line("Pipe mode ready. Awaiting task instruction.")
                io.flush()
            elseif cmd.action == "HELP" then
                io.write(command_parser.HELP_TEXT)
                io.flush()
            elseif cmd.action == "ABORT" then
                ui.printer.pipe_marker("=== PIPE MODE EXIT ===")
                break
            elseif cmd.action == "NEXT_STAGE" or cmd.action == "PREV_STAGE" or cmd.action == "SWITCH_STAGE" then
                ui.printer.line("[WARNING] Not available in pipe mode.")
                io.flush()
            elseif cmd.action == "ERROR" then
                ui.printer.line(cmd.message)
                io.flush()
            elseif cmd.action == "MESSAGE" then
                if trimmed ~= "" then
                    ui.printer.pipe_marker("=== RESPONSE START ===")
                    M.setup_and_run_task(nil, trimmed, nil, ctx, config, utils, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
                    ui.printer.pipe_marker("=== RESPONSE END ===")
                    io.flush()
                end
            else
                if trimmed ~= "" then
                    ui.printer.pipe_marker("=== RESPONSE START ===")
                    M.setup_and_run_task(nil, trimmed, nil, ctx, config, utils, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
                    ui.printer.pipe_marker("=== RESPONSE END ===")
                    io.flush()
                end
            end
        else
            if trimmed ~= "" then
                ui.printer.pipe_marker("=== RESPONSE START ===")
                M.setup_and_run_task(nil, trimmed, nil, ctx, config, utils, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
                ui.printer.pipe_marker("=== RESPONSE END ===")
                io.flush()
            end
        end
    end
end

return M