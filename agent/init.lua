local utils = require("utils")
local logger = require("logger")
local ContextFlow = require("context_flow")
local tools = require("tools")
local os = require("os")
local status_server = require("status_server")
local json_logger = require("json_logger")
local ui = require("ui")


-- Submodules

local config_loader = require("agent.config")
local state_mgr = require("agent.state")
local cli_parser = require("agent.cli")
local custom_tools_loader = require("agent.custom_tools")
local multi_stage = require("agent.multi_stage")
local turn_module = require("agent.turn")
local pipeline_module = require("agent.pipeline")
local task_module = require("agent.task")
local bootstrap_module = require("agent.bootstrap")

local agent_home = os.getenv("AGENT_HOME") or "."
local project_root = os.getenv("PROJECT_ROOT") or "."


-- 1. Load Config
local config = assert(config_loader.load_config(agent_home, project_root, utils), "CRITICAL: Could not load config")
-- 1.2 Startup Diagnostics
ui.diagnostics.print_startup_diagnostics(config)
-- 1.5 Start Observability (Status Server + JSON Logger)
local status_port = tonumber(os.getenv("EVA_STATUS_PORT")) or 8080
status_server.start(status_port)
ui.printer.line(string.format("[OBSERVABILITY] Status server started on http://localhost:%d/status", status_port))
json_logger.init("INIT", 0, "startup")
-- Shutdown hook: clean up on exit + crash reporting
local orig_exit = os.exit
local _crash_report_printed = false
local function print_crash_report(code)
    if _crash_report_printed then return end
    _crash_report_printed = true
    local st = status_server._status or {}
    ui.crash_report.print_crash_report(code, st)
end
os.exit = function(code)
    print_crash_report(code)
    status_server.stop()
    json_logger.flush()
    orig_exit(code)
end
-- SIGTERM/SIGINT handler: flush logs and print final status
local function _signal_handler(sig_name)
    ui.crash_report.print_signal_received(sig_name)
    json_logger.flush()
    status_server.stop()
    os.exit(128 + (#sig_name == 6 and 2 or 13)) -- SIGTERM=143, SIGINT=144
end
-- Register signal handlers via debug.sethook won't catch signals,
-- but we can use a background thread approach. For Lua 5.1, we rely on
-- the C-level signal handling. Instead, we set up a periodic check.
-- The most reliable approach in pure Lua is to override os.exit (done above)
-- and ensure json_logger/status_server flush on any exit path.
-- 2. Initialize ContextFlow
local ctx = ContextFlow.new(config.CONTEXT_FLOW, config)
local STATE_FILE = state_mgr.get_state_file_path(config)


-- 3. Initialize Tools & Patcher
tools.init(config)

local patcher_core = require("patcher_core")

if type(patcher_core.setup_sigint) == "function" then
    patcher_core.setup_sigint()
end


-- 4. Load Custom Tools
custom_tools_loader.load_custom_tools(config, require("tool_registry"), utils, ContextFlow, logger)
-- 5. Parse CLI Args
-- Since agent.init is loaded via require() from agent.lua, varargs (...) are empty.
-- Use the global arg table instead, skipping arg[0] (script name).
local cli_args = {}
for i = 1, #arg do
    cli_args[i] = arg[i]
end
local parsed = cli_parser.parse_args(cli_args, config, logger)
-- 6. Handle Pipe Mode (Must be before session restoration)
if parsed.is_pipe then
    status_server.update_status({agent_name="PIPE", current_turn=0, current_stage="pipe_mode", stage_index=0, total_stages=0, state="running"})
    task_module.run_pipe_mode(ctx, config, utils, logger, pipeline_module.execute_pipeline, turn_module.run_agent_turn, STATE_FILE)
    status_server.update_status({state="idle"})
    return -- Exit after pipe mode finishes (or breaks)
end
-- 7. Load Instruction from task.txt if not provided
local instruction = parsed.instruction

if not instruction then
    local task_path = config.PROJECT_ROOT .. '/.e-va-conf/task.txt'
    local task_content = utils.read_file_range(task_path)

    if task_content and task_content ~= '' then
        instruction = utils.trim(task_content)
    end
end


-- 7. Handle Session Restoration

local restored = state_mgr.restore_session(STATE_FILE, ctx, utils)


-- 8. Helper: resolve task instruction for batch tasks

local function resolve_task_instruction(task, cfg, u, l)
    local instr = task.instruction

    if task.instruction_file then
        local instr_path = cfg.PROJECT_ROOT .. "/.e-va-conf/" .. task.instruction_file
        local file_content = u.read_file_range(instr_path)

        if file_content then
            instr = u.trim(file_content)
            task.instruction = instr
        else

            l.error("IO_ERROR: Could not read instruction_file at " .. instr_path)
            return nil, "Missing instruction_file mapping"
        end

    end

    return instr, nil
end


-- 9. Dispatch to correct mode


if not restored then
    if parsed.is_bootstrap then
        -- Bootstrap Mode
        bootstrap_module.run_bootstrap(config, ctx, logger, pipeline_module.execute_pipeline, turn_module.run_agent_turn, STATE_FILE)
    elseif instruction or parsed.target_agent then
        -- Single Task Mode
        task_module.setup_and_run_task(parsed.start_file, instruction, nil, ctx, config, utils, logger, pipeline_module.execute_pipeline, turn_module.run_agent_turn, STATE_FILE)
    elseif ctx.config.TASKS and #ctx.config.TASKS > 0 then
        -- Batch Task Mode
        logger.info(string.format("Batch processing initiated. Found %d tasks.", #ctx.config.TASKS))
        for i, task in ipairs(ctx.config.TASKS) do
            local instr, err = resolve_task_instruction(task, config, utils, logger)
            if err then
                logger.error(err)
                instr = "FATAL_MISSING_FILE"
            end
            ui.progress.batch_task_header(i, #ctx.config.TASKS, task.file or "Global Context")
            local status, e = pcall(function()
                task_module.setup_and_run_task(task.file, instr, task.max_turns, ctx, config, utils, logger, pipeline_module.execute_pipeline, turn_module.run_agent_turn, STATE_FILE)
            end)
            if not status then
                logger.error("Task failed fatally: " .. tostring(e))
                if config.PIPELINE_SETTINGS and config.PIPELINE_SETTINGS.ABORT_ON_FATAL then
                    ui.printer.line("\n[SYSTEM] Aborting batch execution due to fatal error in task " .. i)
                    os.exit(1)
                end
            end
            ui.printer.line(string.format("\n=== FINISHED TASK [%d/%d] ===", i, #ctx.config.TASKS))
        end
    else
        ui.printer.line("Usage: eva [file] \"<instruction>\" OR define TASKS in .e-va-conf/config.lua")
        os.exit(1)
    end
else
    -- Restored Session: Execute Pipeline
    pipeline_module.execute_pipeline(ctx, config, logger, turn_module.run_agent_turn, STATE_FILE)
end