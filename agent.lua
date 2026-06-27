local utils = require("utils")
local inspect = require('inspect')
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

local logger = require("logger")
local ContextFlow = require("context_flow")
local registry = require("tool_registry")
local tools = require("tools")
local os = require("os")

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

if utils.read_file_range(STATE_FILE) then
    local content = utils.read_file_range(STATE_FILE)
    if ctx:load_from_snapshot(content) then restored = true end
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

local function run_agent_turn(agent_name, agent_cfg, turn)
    ctx.consecutive_recoveries = 0
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

    io.write(string.format("\n\27[35m>>> AI (%s):\27[0m ", tostring(agent_name)))
    local print_buf = ""
    local in_thought = agent_cfg.is_reasoning or false
    local tag_open = "<think>"
    local tag_close = "</think>"

    if in_thought then io.write("\27[90m") end

    local response_data, err
    local max_retries, retry_delay = 5, 5
    local interruption_retries, MAX_INTERRUPTION_RETRIES = 0, 3

    local on_token_fn = function(t)
        print_buf = print_buf .. t
        while #print_buf > 0 do
            if not in_thought then
                local s, e = print_buf:find(tag_open)
                if s then
                    io.write(print_buf:sub(1, s - 1) .. "\27[90m" .. tag_open)
                    print_buf = print_buf:sub(e + 1)
                    in_thought = true
                elseif #print_buf > #tag_open then
                    local safe_len = #print_buf - #tag_open
                    io.write(print_buf:sub(1, safe_len))
                    print_buf = print_buf:sub(safe_len + 1)
                else break end
            else
                local s, e = print_buf:find(tag_close)
                if s then
                    io.write(print_buf:sub(1, s - 1) .. tag_close .. "\27[0m")
                    print_buf = print_buf:sub(e + 1)
                    in_thought = false
                elseif #print_buf > #tag_close then
                    local safe_len = #print_buf - #tag_close
                    io.write(print_buf:sub(1, safe_len))
                    print_buf = print_buf:sub(safe_len + 1)
                else break end
            end
        end
        io.flush()
    end

    while true do
        for attempt = 1, max_retries do
            response_data, err = llm.send_request(agent_cfg, messages, { on_token = on_token_fn })
            if response_data then break end
            if type(err) == 'table' and err.type == 'CONTEXT_EXCEEDED' then
                local new_val = context_optimizer.shrink_max_tokens(agent_cfg, config.AGENT_DEFAULTS.min_max_tokens or 1024)
                logger.info(string.format('[CONTEXT OPTIMIZATION] Reduced max_tokens to %d', new_val))
            else
                logger.warn(string.format("\n[NETWORK INCIDENT] LLM API Error (Attempt %d/%d): %s", attempt, max_retries, tostring(err)))
            end
            if attempt < max_retries then
                print(string.format("\27[33m[SYSTEM] Retrying in %d seconds...\27[0m", retry_delay))
                os.execute("sleep " .. tostring(retry_delay))
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

    if print_buf ~= "" then
        if in_thought then io.write(print_buf .. "\27[0m") else io.write(print_buf) end
    end
    io.write("\n")

    if not response_data then
        logger.error("FATAL: Network unreachable after " .. max_retries .. " attempts.", err)
        return "ERROR"
    end
    --
    -- 1. Извлекаем текст ответа
    local content = ""
    if response_data.choices and response_data.choices[1] and response_data.choices[1].message then
        content = response_data.choices[1].message.content
    end

    if content == "" then
        logger.warn("Empty response from LLM")
        return nil
    end

    -- 2. Передаем ответ в новый модуль контекста
    -- process_turn_response сам выполнит команду, обновит историю и сделает squash если нужно
    local result = ctx:process_turn_response(agent_name, content, executor)

    -- 3. Обрабатываем результат
    if result.type == "COMPLETED" then
        return "PIPELINE_NEXT_STAGE" -- Сигнал для завершения стадии
    elseif result.type == "ERROR" then
        logger.error("Agent execution error: " .. (result.message or "Unknown error"))
        -- Можно вернуть ошибку или продолжить, в зависимости от логики
        return "ERROR"
    end
    save_state()

    -- Если это просто разговор или успешное выполнение команды (не завершающее)
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
                local target_agent = "ARCHITECT"
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
                        
                        -- Исправленная логика:
                        if sig == "PIPELINE_NEXT_STAGE" then
                            print("\n\27[33m[SYSTEM] Agent requested next stage. Type '/go' to proceed.\27[0m")
                        elseif sig == "ERROR" then
                            print("\n\27[31m[SYSTEM] Error occurred during agent turn. Please try again.\27[0m")
                        else
                            -- Тут мы ничего не печатаем специально, потому что run_agent_turn
                            -- уже добавил результат выполнения команды (или текст чата) в историю.
                            -- Но если мы хотим подтверждение выполнения команды:
                            -- (Опционально можно добавить проверку на tyep == EXECUTED через контекст)
                            turn = turn + 1
                        end
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
          end
          current_stage_idx = current_stage_idx + 1
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
    end

    if ctx.file_tree then
        for line in ctx.file_tree:gmatch("[^\r\n]+") do
            local filepath = line:match("^(%S+)")
            if filepath and filepath:lower() ~= "readme.md" then
                if not filepath:find("/") and filepath:match("^[A-Z0-9_-]+%.[mM][dD]$") then
                    local content = utils.read_file_range(config.PROJECT_ROOT .. "/" .. filepath)
                    if content then
                        ctx:add_file(filepath, content)
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
            ctx:track_requested_file(norm_start)
            initial_msg = initial_msg .. "\n(Note: I loaded target file '"..norm_start.."' for you)"
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
            allowed_tools = { "explore_tree", "read_file", "search", "create_file", "shell", "task_complete" }
        }

        config.PIPELINE = {
            { stage = "BOOTSTRAP_DISCOVERY", agents = { "BOOTSTRAPPER" }, mode = "interactive" }
        }

        ctx = ContextFlow.new(config.CONTEXT_FLOW, config)

        local function detect_lint_command()
            local root = config.PROJECT_ROOT

            -- Check for Node.js project
            if utils.read_file_range(root .. "/package.json") then
                return "npm run lint || npm test || echo 'No lint/test script in package.json'"
            end

            -- Check for Rust project
            if utils.read_file_range(root .. "/Cargo.toml") then
                return "cargo clippy -- -D warnings || cargo test || echo 'No lint/test configured'"
            end

            -- Check for Go project
            if utils.read_file_range(root .. "/go.mod") then
                return "go vet ./... || go test ./... || echo 'No lint/test configured'"
            end

            -- Check for Makefile-based project
            if utils.read_file_range(root .. "/Makefile") then
                return "make lint || make test || echo 'No lint/test target in Makefile'"
            end

            -- Fallback
            return "echo 'No standard project manifest found (package.json/Cargo.toml/go.mod/Makefile)'"
        end

        local lint_cmd = detect_lint_command()
        local trigger_msg = string.format([[
1. Explore the project.
2. Generate .e-va-conf/config.lua.
3. For each task in TASKS, assign a reasonable 'max_turns' (e.g., 5 for simple removals, 15 for logic fixes).
4. Generate MD prompts for your agents.
Use 
>>> COMMAND >>>
task_complete
>>> END_COMMAND >>> 
when the scaffold is ready.
]], lint_cmd)

        if instruction and instruction ~= "" then
            trigger_msg = trigger_msg .. "\n\n[USER CONTEXT]: " .. instruction
        end

        ctx:add_message("BOOTSTRAPPER", "user", trigger_msg)
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