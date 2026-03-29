-- [ЯДЕРНЫЙ ФИКС]: Прямая загрузка файла в обход системного LUA_PATH
local agent_home = os.getenv("AGENT_HOME") or "."
local project_root = os.getenv("PROJECT_ROOT") or "."

local config_func, err = loadfile(project_root .. "/.e-va-conf/config.lua")
if not config_func then
    config_func, err = assert(loadfile(agent_home .. "/config.lua"), "CRITICAL: Could not find config.lua in " .. agent_home)
end

local config_module = config_func()
local config = config_module.get()

-- [HOT-PATCH]: Строгая проверка целостности массива пайплайна
if type(config.PIPELINE) ~= "table" or #config.PIPELINE == 0 then
    print("\n\27[33m[SYSTEM WARNING]: Bypassing config file. Injecting memory-safe PIPELINE.\27[0m")
    config.PIPELINE = {
        { stage = "ANALYSIS_AND_PLANNING", agents = { "ARCHITECT" }, mode = "sequential" },
        { stage = "REVIEW_AND_CHAT", agents = { "ARCHITECT" }, mode = "interactive" },
        { stage = "IMPLEMENTATION", agents = { "CODER" }, mode = "sequential" }
    }
end

-- Загрузка остальных модулей
local llm = require("llm_handler")
local logger = require("logger")
local Context = require("context")
local registry = require("tool_registry")
local core_tools = require("core_tools")
local utils = require("utils")

local os = require("os")

local ctx = Context.new(config)

local STATE_FILE = ".e-va_state.json"
local restored = false

if utils.read_file_range(STATE_FILE) then
    local content = utils.read_file_range(STATE_FILE)
    if ctx:load_from_snapshot(content) then restored = true end
end

core_tools.init()

local arg1, arg2 = ...
local cli_args = arg or _G.arg or {}
local raw_start_file = arg1 or cli_args
local raw_instruction = arg2 or cli_args

local start_file = type(raw_start_file) == "string" and raw_start_file or nil
local instruction = type(raw_instruction) == "string" and raw_instruction or nil

if not restored and not instruction then
    print("Usage: eva [file] \"<instruction>\""); os.exit(1)
end

-- ИСПРАВЛЕНИЕ: Умная загрузка промптов (Local Override -> Global Fallback)
local function load_prompt(file_path)
    local agent_home = os.getenv("AGENT_HOME") or "."

    -- 1. Сначала ищем кастомный промпт в локальной конфигурации проекта
    local local_path = config.PROJECT_ROOT .. "/.e-va-conf/" .. file_path
    local content = utils.read_file_range(local_path)

    -- 2. Если локального нет, берем дефолтный из ядра E-va
    if not content then
        local global_path = agent_home .. "/" .. file_path
        content = utils.read_file_range(global_path)
    end

    if not content then
        logger.warn("Failed to load prompt from both local and global paths: " .. file_path)
        return "You are an AI assistant. Follow the user's instructions."
    end
    return content
end

-- Основная функция хода агента
local function run_agent_turn(agent_name, agent_cfg, turn)
    local synced_files = ctx:sync_files()
    if #synced_files > 0 then
        logger.info(string.format("[FS WATCHER] Auto-synced %d changed file(s): %s", #synced_files, table.concat(synced_files, ", ")))
    end

    local limits = config.LIMITS
    local available_tokens = limits.MAX_CONTEXT - limits.RESERVED_OUTPUT - limits.SYSTEM_PROMPT_ESTIMATE

    local memory_budget = math.floor(available_tokens * limits.MEMORY_RATIO)
    local chat_budget = available_tokens - memory_budget

    local memory_block = ctx:get_memory_block(memory_budget)
    local sys_prompt_text = load_prompt(agent_cfg.prompt_file)

    local digest_budget = math.floor(chat_budget * 0.2)
    local search_digest = ctx:get_search_digest(digest_budget)

    local combined_system_prompt = sys_prompt_text .. "\n\n" .. ctx:get_report(agent_name) .. ctx:get_thoughts_digest() .. "\n\n" .. search_digest .. "\n\n" .. memory_block

    local messages = { { role = "system", content = combined_system_prompt } }

    local chat_buffer = {}
    local current_chat_cost = 0
    local history = ctx:get_history(agent_name)

    local history_len = #history

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

    local total_ctx_tokens = ctx:estimate_tokens(combined_system_prompt)

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

    -- [FULL TRACE DUMP]: Логируем точный контекст перед отправкой
    local json = require("JSON")
    local trace_dump = json:encode({
        turn = turn,
        agent = agent_name,
        tokens = total_ctx_tokens,
        payload = messages
    })
    logger.log_context(turn, agent_name .. "_PROMPT", trace_dump)

    logger.info(string.format("[TURN %d] Agent: %s | Active Context Tokens: ~%d / %d", turn, tostring(agent_name), total_ctx_tokens, limits.MAX_CONTEXT))

    io.write(string.format("\n\27[35m>>> AI (%s):\27[0m ", tostring(agent_name)))

    local print_buf = ""
    local in_thought = false
    local tag_open = "<think>"
    local tag_close = "</think>"

    local response_data, err = llm.send_request(agent_cfg, messages, {
        on_token = function(t)
            print_buf = print_buf .. t
            if not in_thought then
                local s, e = print_buf:find(tag_open)
                if s then
                    io.write(print_buf:sub(1, s - 1)); io.flush()
                    print_buf = print_buf:sub(e + 1)
                    in_thought = true
                elseif #print_buf > #tag_open then
                    local safe_len = #print_buf - #tag_open
                    io.write(print_buf:sub(1, safe_len)); io.flush()
                    print_buf = print_buf:sub(safe_len + 1)
                end
            else
                local s, e = print_buf:find(tag_close)
                if s then
                    print_buf = print_buf:sub(e + 1)
                    in_thought = false
                end
            end
        end
    })

    if print_buf ~= "" and not in_thought then io.write(print_buf) end
    io.write("\n")

    if not response_data then
        logger.error("Network Error for " .. tostring(agent_name), err)
        os.execute("sleep 3")
        return "ERROR"
    end

    local raw_content = llm.extract_content(response_data) or ""
    local thought = ""
    local content = raw_content

    -- 1. Умное извлечение мыслей, даже если теги повреждены
    local end_idx = content:find("</think>")
    if end_idx then
        local start_idx = content:find("<think>")
        if start_idx and start_idx < end_idx then
            thought = content:sub(start_idx + 7, end_idx - 1)
            content = content:sub(1, start_idx - 1) .. content:sub(end_idx + 8)
        else
            thought = content:sub(1, end_idx - 1)
            content = content:sub(end_idx + 8)
        end
    else
        local start_idx = content:find("<think>")
        if start_idx then
            thought = content:sub(start_idx + 7)
            content = content:sub(1, start_idx - 1)
        end
    end

    thought = require("utils").trim(thought)
    content = require("utils").trim(content)

    -- 2. Сохраняем мысли для дайджеста
    if thought ~= "" then ctx:add_thought(turn, thought) end

    content = content:gsub(">>>>>>> REPLACE%s*\n?%s*</file_target>", ">>>>>>> REPLACE\n</cmd>")

    -- 3. Формируем ИДЕАЛЬНОЕ сообщение ассистента для истории (исправляем сломанные теги)
    local signal = nil
    local cmds_executed = 0
    local MAX_CMDS_PER_TURN = 5
    local safe_assistant_content = ""
    local spammed = false

    for cmd_block in content:gmatch("<cmd>(.-)</cmd>") do
        cmds_executed = cmds_executed + 1
        if cmds_executed > MAX_CMDS_PER_TURN then
            spammed = true
            break
        end
        safe_assistant_content = safe_assistant_content .. "<cmd>" .. cmd_block .. "</cmd>\n"
    end

    local final_history_content = ""
    if thought ~= "" then
        final_history_content = "<think>\n" .. thought .. "\n</think>\n"
    end

    if spammed then
        final_history_content = final_history_content .. safe_assistant_content
    else
        final_history_content = final_history_content .. content
    end

    -- СТРОГО ОДИН РАЗ записываем сообщение агента в историю ДО выполнения инструментов
    ctx:add_message(agent_name, "assistant", final_history_content)

    -- 4. Физически выполняем инструменты и сохраняем результаты системы
    local run_count = 0
    for cmd_block in content:gmatch("<cmd>(.-)</cmd>") do
        run_count = run_count + 1
        if run_count > MAX_CMDS_PER_TURN then
            local warn_msg = string.format("\n[SYSTEM NOTE]: You reached the execution limit of %d commands per turn. Remaining commands were safely ignored.", MAX_CMDS_PER_TURN)
            print("\27[33m" .. warn_msg .. "\27[0m")
            ctx:add_message(agent_name, "user", warn_msg)
            break
        end

        local res = registry.execute(cmd_block, ctx, agent_name)
        if res.output and res.output ~= "" then
            local display_out = res.output
            if #display_out > 500 then display_out = display_out:sub(1, 500) .. "\n...[TRUNCATED IN UI]" end
            print("\27[36m" .. display_out .. "\27[0m")

            ctx:add_message(agent_name, "user", res.output)
        end
        if res.signal then signal = res.signal end

        if signal == "PIPELINE_NEXT_STAGE" then break end
    end

    if cmds_executed == 0 then
         local warn_msg = "\n[SYSTEM]: You did not execute any valid <cmd>. Remember your directive. You MUST use tools to act, delegate using <cmd>delegate_plan</cmd>, or finish the turn using <cmd>task_complete</cmd>."
         ctx:add_message(agent_name, "user", warn_msg)
    end

    utils.write_file(STATE_FILE, ctx:snapshot())
    return signal
end

local function execute_pipeline()
    local turn = 1
    local MAX_TURNS = 150

    for stage_idx, stage in ipairs(config.PIPELINE) do
        logger.info(string.format("\n=== PIPELINE STAGE [%d/%d]: %s ===", stage_idx, #config.PIPELINE, tostring(stage.stage)))

        local stage_complete = false

        while not stage_complete and turn < MAX_TURNS do
            turn = turn + 1

            if stage.mode == "interactive" then
                -- Строгое определение типа агента (Type Bounds Checking)
                local target_agent = "ARCHITECT"
                if type(stage.agent) == "string" then 
                    target_agent = stage.agent
                elseif type(stage.agents) == "table" and type(stage.agents) == "string" then 
                    target_agent = stage.agents
                elseif type(stage.agents) == "string" then
                    target_agent = stage.agents
                end

                logger.info(string.format("[INTERACTIVE MODE] Hooked to agent: %s", target_agent))
                io.write("\n\27[36m=== HUMAN-IN-THE-LOOP (HITL) SESSION ===\27[0m\n")
                io.write("Type your message. Commands: '/continue' (next stage), '/exit' (abort).\n")

                while true do
                    io.write(string.format("\n\27[36m>>> USER -> %s:\27[0m ", target_agent))
                    local user_input = io.read("*l")

                    if not user_input or user_input == "/exit" then
                        print("\n\27[31m[SYSTEM] User aborted the execution.\27[0m")
                        os.exit(0)
                    elseif user_input == "/continue" then
                        print("\n\27[32m[SYSTEM] Moving to the next pipeline stage...\27[0m")
                        stage_complete = true
                        break
                    elseif require("utils").trim(user_input) ~= "" then
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
                    local co = coroutine.create(function()
                        return run_agent_turn(agent_name, config.AGENTS[agent_name], turn)
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

if not restored then
    local initial_msg = "TASK: " .. instruction
    local docs_loaded = {}

    ctx.file_tree = utils.list_files_recursive(config.PROJECT_ROOT)

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

    if start_file then
        local norm_start = utils.normalize_path(config.PROJECT_ROOT, start_file)
        local content = utils.read_file_range(config.PROJECT_ROOT .. "/" .. norm_start)
        if content then
            ctx:add_file(norm_start, content)
            initial_msg = initial_msg .. "\n(Note: I loaded target file '"..norm_start.."' for you)"
        end
    end

    -- 5. Изолированное извлечение первого агента
    local first_agent = "ARCHITECT"
    if type(config.PIPELINE) == "table" and config.PIPELINE and type(config.PIPELINE.agents) == "table" and type(config.PIPELINE.agents) == "string" then
        first_agent = config.PIPELINE.agents
    end

    ctx:add_message(first_agent, "user", initial_msg)
end

execute_pipeline()
