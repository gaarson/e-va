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
local optimizer = require("optimizer")

local logger = require("logger")
local Context = require("context")
local registry = require("tool_registry")
local tools = require("tools")
local parser = require("parser")
local os = require("os")

local ctx = Context.new(config)
local STATE_FILE = config.PROJECT_ROOT .. "/.e-va-conf/.state.json"

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

local function load_prompt(file_path)
    if not file_path then return "You are an AI assistant. Follow the user's instructions." end

    local local_path = config.PROJECT_ROOT .. "/.e-va-conf/" .. file_path
    local content = utils.read_file_range(local_path)

    if not content then
        local proj_path = config.PROJECT_ROOT .. "/" .. file_path
        content = utils.read_file_range(proj_path)
    end

    if not content then
        local global_path = agent_home .. "/" .. file_path
        content = utils.read_file_range(global_path)
    end

    if not content then
        logger.warn("Failed to load prompt from all paths: " .. file_path)
        return "You are an AI assistant. Follow the user's instructions."
    end
    return content
end

local function parse_think_tags(text, is_reasoning)
    if not text or text == "" then return "", "" end

    local content = text
    local thought = ""
    local start_idx = content:find("<think>")

    if start_idx then
        local prefix = content:sub(1, start_idx - 1)
        local end_idx = content:find("</think>", start_idx + 7)
        if end_idx then
            thought = content:sub(start_idx + 7, end_idx - 1)
            content = prefix .. content:sub(end_idx + 8)
        else
            if is_reasoning then
                thought = content:sub(start_idx + 7)
                content = prefix
            else
                content = prefix .. content:sub(start_idx)
                thought = ""
            end
        end
    elseif is_reasoning then
        local end_idx = content:find("</think>")
        if end_idx then
            thought = content:sub(1, end_idx - 1)
            content = content:sub(end_idx + 8)
        else
            thought = content
            content = ""
        end
    end

    thought = utils.trim(thought)
    if thought == "" then thought = nil end

    return utils.trim(content), thought
end

local function run_agent_turn(agent_name, agent_cfg, turn)
    ctx.consecutive_recoveries = 0  -- Reset recovery counter at start of each turn
    local synced_files = ctx:sync_files()
    if #synced_files > 0 then
        logger.info(string.format("[FS WATCHER] Auto-synced %d changed file(s): %s", #synced_files, table.concat(synced_files, ", ")))
    end

    ctx:clear_turn_requested_files()

    local limits = config.LIMITS
    local available_tokens = limits.MAX_CONTEXT - limits.RESERVED_OUTPUT - limits.SYSTEM_PROMPT_ESTIMATE

    local memory_budget = math.floor(available_tokens * limits.MEMORY_RATIO)
    local chat_budget = available_tokens - memory_budget

    local max_commands = ctx:calculate_max_commands(agent_name, available_tokens)

    local memory_block = ctx:get_memory_block(memory_budget)

    local digest_budget = math.floor(chat_budget * 0.2)
    local search_digest = ctx:get_search_digest(digest_budget)

    -- System prompt is now assembled centrally in context/init.lua:get_system_prompt()
    local system_prompt = ctx:get_system_prompt(agent_name, agent_cfg)
    -- dynamic_context removed: replaced by recency block injection in last user message

    local messages = { { role = "system", content = system_prompt } }

    local chat_buffer = {}
    local current_chat_cost = 0
    local history = ctx:get_history(agent_name)
    local history_len = #history

    local REINFORCEMENT_INTERVAL = 5
    if turn > 1 and turn % REINFORCEMENT_INTERVAL == 0 then
        local current_task = ctx.execution_plan[ctx.current_task_index]
        if current_task then
            local reminder = string.format(
                "\n[SYSTEM REMINDER]: You are currently working on Step %d/%d.\n" ..
                "Task: %s\n" ..
                "File: %s\n" ..
                "Please ensure you are still following the plan.",
                ctx.current_task_index,
                #ctx.execution_plan,
                current_task.instruction,
                current_task.file
            )
            table.insert(chat_buffer, { role = "user", content = reminder })
            current_chat_cost = current_chat_cost + ctx:estimate_tokens(reminder)
        end
    end

    if history_len > 0 then
        for i = history_len, 1, -1 do
            local msg = history[i]
            local cost = ctx:estimate_tokens(msg.content or "")
            if (current_chat_cost + cost) < chat_budget then
                table.insert(chat_buffer, 1, msg)
                current_chat_cost = current_chat_cost + cost
            else break end
        end
    end

    -- Recency block injection: APPEND to the LAST user message in chat_buffer
    local recency_block = ctx:get_recency_block(ctx)
    for i = #chat_buffer, 1, -1 do
        if chat_buffer[i].role == "user" then
            chat_buffer[i].content = chat_buffer[i].content .. "\n\n" .. recency_block
            break
        end
    end

    local total_ctx_tokens = ctx:estimate_tokens(system_prompt)

    if history_len == 0 then
        if ctx.handoff_memo and ctx.handoff_memo ~= "" then
            local handoff_msg = "[SYSTEM: HANDOFF MEMO FROM PREVIOUS STAGE]\n" .. ctx.handoff_memo
            table.insert(chat_buffer, { role = "user", content = handoff_msg })
            total_ctx_tokens = total_ctx_tokens + ctx:estimate_tokens(handoff_msg)
        else
            local default_msg = "[SYSTEM: INITIATION]\nYou have been assigned to this pipeline stage. Please review the context. If no explicit task was delegated to your role, analyze the state and take action, or execute <cmd>task_complete</cmd>."
            table.insert(chat_buffer, { role = "user", content = default_msg })
            total_ctx_tokens = total_ctx_tokens + ctx:estimate_tokens(default_msg)
        end
    end

    for _, msg in ipairs(chat_buffer) do
      local safe_role = msg.role
        if safe_role == "system" then safe_role = "user" end
        table.insert(messages, { role = safe_role, content = msg.content })
        total_ctx_tokens = total_ctx_tokens + ctx:estimate_tokens(msg.content)
    end

    -- Image injection logic
    if config.PICTURES_DIR then
        ctx:load_images(config.PROJECT_ROOT .. "/" .. config.PICTURES_DIR)
    end
    local image_parts = ctx:get_image_content_parts()
    if #image_parts > 0 then
        for i = 1, #messages do
            if messages[i].role == "user" then
                local original_content = messages[i].content
                messages[i].content = {
                    { type = "text", text = original_content },
                    unpack(image_parts)
                }
                break
            end
        end
    end

    local json = require("JSON")
    local trace_dump = json:encode({
        turn = turn,
        agent = agent_name,
        tokens = total_ctx_tokens,
        payload = messages
    })
    logger.log_context(turn, agent_name .. "_PROMPT", trace_dump)

    logger.log_messages_pretty(messages, turn, agent_name, ctx)

    logger.info(string.format("[TURN %d] Agent: %s | Active Context Tokens: ~%d / %d", turn, tostring(agent_name), total_ctx_tokens, limits.MAX_CONTEXT))

    io.write(string.format("\n\27[35m>>> AI (%s):\27[0m ", tostring(agent_name)))

    local print_buf = ""
    local in_thought = agent_cfg.is_reasoning or false
    local tag_open = "<think>"
    local tag_close = "</think>"

    if in_thought then io.write("\27[90m") end

    local response_data, err
    local max_retries = 5
    local retry_delay = 5
    local interruption_retries = 0
    local MAX_INTERRUPTION_RETRIES = 3

    local on_token_fn = function(t)
        print_buf = print_buf .. t
        while #print_buf > 0 do
            if not in_thought then
                local s, e = print_buf:find(tag_open)
                if s then
                    io.write(print_buf:sub(1, s - 1))
                    io.write("\27[90m" .. tag_open)
                    print_buf = print_buf:sub(e + 1)
                    in_thought = true
                elseif #print_buf > #tag_open then
                    local safe_len = #print_buf - #tag_open
                    io.write(print_buf:sub(1, safe_len))
                    print_buf = print_buf:sub(safe_len + 1)
                else
                    break
                end
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
                else
                    break
                end
            end
        end
        io.flush()
    end

    while true do
        for attempt = 1, max_retries do
            response_data, err = llm.send_request(agent_cfg, messages, { on_token = on_token_fn })
            if response_data then break end
            logger.warn(string.format("\n[NETWORK INCIDENT] LLM API Error (Attempt %d/%d): %s", attempt, max_retries, tostring(err)))
            if attempt < max_retries then
                print(string.format("\27[33m[SYSTEM] Retrying in %d seconds...\27[0m", retry_delay))
                os.execute("sleep " .. tostring(retry_delay))
                retry_delay = retry_delay * 3
            end
        end

        if not response_data then break end

        if response_data.interrupted then
            interruption_retries = interruption_retries + 1
            if interruption_retries > MAX_INTERRUPTION_RETRIES then
                logger.warn("[SYSTEM] Max interruption retries reached. Resuming with current context.")
                break
            end
            print("\n\27[33m[SYSTEM] Generation interrupted. Provide additional context or corrections (or press Enter to continue):\27[0m")
            local user_input = io.read("*l")
            if user_input and user_input ~= "" then
                table.insert(messages, { role = "user", content = user_input })
            end
            response_data = nil
        else
            break
        end
    end

    if print_buf ~= "" then
        if in_thought then io.write(print_buf .. "\27[0m")
        else io.write(print_buf) end
    end
    io.write("\n")

    if not response_data then
        logger.error("FATAL: Network unreachable after " .. max_retries .. " attempts.", err)
        return "ERROR"
    end

    local raw_content = llm.extract_content(response_data) or ""
    local content, thought = parse_think_tags(raw_content, agent_cfg.is_reasoning)

    content = utils.trim(content)

    if thought and #thought > 0 and (#content == 0 or content == "") then
        ctx.consecutive_recoveries = (ctx.consecutive_recoveries or 0) + 1
        logger.warn(string.format("[AGENT] Detected unclosed reasoning block. Attempting recovery... (consecutive: %d)", ctx.consecutive_recoveries))

        if ctx.consecutive_recoveries >= 3 then
            logger.error("[AGENT] Circuit breaker triggered: 3 consecutive recoveries. Advancing to next stage to break infinite loop.")
            return "PIPELINE_NEXT_STAGE"
        end

        local summarized = optimizer.summarize_unclosed_thought(thought, config)
        if summarized then
            content = summarized
            logger.info("[AGENT] Successfully recovered from unclosed reasoning.")

            ctx:add_message(agent_name, "user", "[SYSTEM RECOVERY: Your previous generation was interrupted. I have reconstructed your intent from the unclosed reasoning block. IMPORTANT: You MUST output at least one <cmd> command tag in your response. Do NOT output only reasoning text. Proceed with the next steps based on this summary.]\n")
        else
            logger.error("[AGENT] Failed to recover from unclosed reasoning. Discarding thought.")
            thought = nil
        end
    end

    if thought ~= "" then ctx:add_thought(turn, thought) end

    local signal = nil
    local cmds_executed = 0
    local MAX_CMDS_PER_TURN = 5
    local safe_assistant_content = ""
    local spammed = false

    local cmd_iterator = parser.extract_commands(content)
    for cmd_block in cmd_iterator do
        cmds_executed = cmds_executed + 1
        if cmds_executed > MAX_CMDS_PER_TURN then
            spammed = true
            break
        end
        safe_assistant_content = safe_assistant_content .. "<cmd>" .. cmd_block .. "</cmd>\n"
    end

    local final_history_content = ""

    if spammed then
        final_history_content = final_history_content .. safe_assistant_content
    else
        final_history_content = final_history_content .. content
    end

    ctx:add_message(agent_name, "assistant", final_history_content)
    ctx:squash_last_mutation(agent_name)

    local run_count = 0
    local cmd_iterator_exec = parser.extract_commands(content)
    for cmd_block in cmd_iterator_exec do
        run_count = run_count + 1
        if run_count > MAX_CMDS_PER_TURN then
            local warn_msg = string.format("\n[SYSTEM NOTE]: You reached the execution limit of %d commands per turn. Remaining commands were safely ignored.", MAX_CMDS_PER_TURN)
            print("\27[33m" .. warn_msg .. "\27[0m")
            ctx:add_message(agent_name, "user", warn_msg)
            break
        end

        local res = registry.execute(cmd_block, ctx, agent_name)

        -- Reset recovery counter on successful command execution
        ctx.consecutive_recoveries = 0

        local tool_name = cmd_block:match("^([^:]+)") or cmd_block

        if res.output and res.output ~= "" then
            local display_out = res.output
            if #display_out > 500 then display_out = display_out:sub(1, 500) .. "\n...[TRUNCATED IN UI]" end
            print("\27[36m" .. display_out .. "\27[0m")
            ctx:add_message(agent_name, "user", res.output)
        end
        if res.signal then signal = res.signal end

        if signal == "PIPELINE_NEXT_STAGE" then break end
    end

    local OPTIMIZER_INTERVAL = 5
    local context_usage_ratio = total_ctx_tokens / (config.LIMITS.MAX_CONTEXT or 250000)
    
    if turn % OPTIMIZER_INTERVAL == 0 or context_usage_ratio > 0.7 then
        logger.info(string.format("[OPTIMIZER TRIGGER] turn=%d | ratio=%.2f", turn, context_usage_ratio))
        local ok, err = pcall(optimizer.analyze_and_optimize, ctx, config)
        if not ok then logger.error("[OPTIMIZER] pcall failed: " .. tostring(err)) end
    end

    utils.write_file(STATE_FILE, ctx:snapshot())

    collectgarbage("collect")

    return signal
end

local function execute_pipeline()
    local turn = 1
    local MAX_TURNS = (config.PIPELINE_SETTINGS and config.PIPELINE_SETTINGS.MAX_TURNS) or 150

    for stage_idx, stage in ipairs(config.PIPELINE) do
        logger.info(string.format("\n=== PIPELINE STAGE [%d/%d]: %s ===", stage_idx, #config.PIPELINE, tostring(stage.stage)))

        local stage_complete = false

        while not stage_complete and turn < MAX_TURNS do
            turn = turn + 1

            if stage.mode == "interactive" then
                local target_agent = "ARCHITECT"
                if type(stage.agent) == "string" then target_agent = stage.agent
                elseif type(stage.agents) == "table" and type(stage.agents[1]) == "string" then target_agent = stage.agents[1]
                elseif type(stage.agents) == "string" then target_agent = stage.agents end

                logger.info(string.format("[INTERACTIVE MODE] Hooked to agent: %s", target_agent))
                io.write("\n\27[36m=== HUMAN-IN-THE-LOOP (HITL) SESSION ===\27[0m\n")
                io.write("Type your message. Commands: '/back' back to anaylis, '/go' (next stage), '/exit' (abort).\n")

                while true do
                    io.write(string.format("\n\27[36m>>> USER -> %s:\27[0m ", target_agent))
                    local user_input = io.read("*l")

                    if not user_input or user_input == "/exit" then
                        print("\n\27[31m[SYSTEM] User aborted the execution.\27[0m")
                        os.exit(0)
                    elseif user_input == "/go" then
                        print("\n\27[32m[SYSTEM] Moving to the next pipeline stage...\27[0m")
                        stage_complete = true
                        break
                    elseif utils.trim(user_input) ~= "" then
                        ctx:add_message(target_agent, "user", user_input)
                        local sig = run_agent_turn(target_agent, config.AGENTS[target_agent], turn)
                        turn = turn + 1
                        if sig == "PIPELINE_NEXT_STAGE" then
                            stage_complete = true
                            break
                        end
                    end
                end
            elseif stage.mode == "parallel" then
                local threads = {}
                for _, a_name in ipairs(stage.agents or {}) do
                    local agent_name = tostring(a_name)
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

if not restored then
    if is_bootstrap then
      print("\n\27[35m[SYSTEM] Initializing Bootstrapper Meta-Agent with High Creativity...\27[0m")

        os.execute("mkdir -p " .. config.PROJECT_ROOT .. "/.e-va-conf/prompts")

        config.AGENTS = config.AGENTS or {}
        local fallback_agent = config.AGENTS.ARCHITECT or {}

        config.AGENTS.BOOTSTRAPPER = {
            name = "BOOTSTRAPPER",
            url = fallback_agent.url or os.getenv("LLM_URL") or "http://127.0.0.1:8000/v1/chat/completions",
            model = fallback_agent.model or os.getenv("LLM_MODEL") or "default-model",
            token = fallback_agent.token or nil,
            params = {
                stream = true,
                temperature = 0.7,
                max_tokens = 8192,
            },
            prompt_file = "prompts/bootstrapper.md",
            allowed_tools = { "explore_tree", "read_file", "search", "create_file", "shell", "task_complete" }
        }

        config.PIPELINE = {
            { stage = "BOOTSTRAP_DISCOVERY", agents = { "BOOTSTRAPPER" }, mode = "sequential" }
        }

        ctx = Context.new(config)

        local trigger_msg = [[
1. Explore the project.
2. Run 'npm run lint:write' (piped through head) to see current errors.
3. Generate .e-va-conf/config.lua. 
4. For each task in TASKS, assign a reasonable 'max_turns' (e.g., 5 for simple removals, 15 for logic fixes).
5. Generate MD prompts for your agents.
Use <cmd>task_complete</cmd> when the scaffold is ready.
]]

        if instruction and instruction ~= "" then
            trigger_msg = trigger_msg .. "\n\n[USER CONTEXT]: " .. instruction
        end

        ctx:add_message("BOOTSTRAPPER", "user", trigger_msg)
        execute_pipeline()
        os.exit(0)

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
