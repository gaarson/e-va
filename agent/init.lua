local utils = require("utils")
local logger = require("logger")
local ContextFlow = require("context_flow")
local tools = require("tools")
local os = require("os")


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

local cli_args = {...}
local parsed = cli_parser.parse_args(cli_args, config, logger)


-- 6. Load Instruction from task.txt if not provided

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
            print(string.format("\n\27[35m=== STARTING TASK [%d/%d]: %s ===\27[0m", i, #ctx.config.TASKS, task.file or "Global Context"))
            local status, e = pcall(function()
                task_module.setup_and_run_task(task.file, instr, task.max_turns, ctx, config, utils, logger, pipeline_module.execute_pipeline, turn_module.run_agent_turn, STATE_FILE)
            end)
            if not status then
                logger.error("Task failed fatally: " .. tostring(e))
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
    -- Restored Session: Execute Pipeline
    pipeline_module.execute_pipeline(ctx, config, logger, turn_module.run_agent_turn, STATE_FILE)
end
