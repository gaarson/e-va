local config_module = require("config")
local llm = require("llm_handler")
local logger = require("logger")
local json = require("JSON")
local Context = require("context")
local Analyzer = require("analyzer")
local tool_executor = require("tool_executor")
local utils = require("utils")
local os = require("os")

local config = config_module.get()
local ctx = Context.new(config)

local STATE_FILE = ".e-va_state.json"
local STATES = { RESEARCH = "RESEARCH", PLANNING = "PLANNING", CODING = "CODING" }
local CURRENT_STATE = STATES.RESEARCH

local restored = false
if utils.read_file_range(STATE_FILE) then
    local content = utils.read_file_range(STATE_FILE)
    if ctx:load_from_snapshot(content) then restored = true end
end

local start_file = arg[1]
local instruction = arg[2]

if not restored then
    if not instruction then print("Usage: eva [file] \"<instruction>\""); os.exit(1) end
    Analyzer.run(ctx, llm)
    local initial_msg = "TASK: " .. instruction
    local docs_loaded = {}

    -- 2. [CONTEXT PRIMING] Жестко ищем README.md
    local readme_path = "README.md"
    local readme_content = utils.read_file_range(config.PROJECT_ROOT .. "/" .. readme_path)
    if readme_content then
        ctx:add_file(readme_path, readme_content)
        table.insert(docs_loaded, readme_path)
    end

    -- 3. Сканируем file_tree на наличие других UPPERCASE.md файлов в корне
    if ctx.file_tree then
        for line in ctx.file_tree:gmatch("[^\r\n]+") do
            -- Извлекаем путь (до первого пробела, т.к. формат "путь (X lines)")
            local filepath = line:match("^(%S+)")
            if filepath and filepath:lower() ~= "readme.md" then
                -- Условие: файл в корне (нет слешей) И имя состоит из заглавных букв/цифр/подчеркиваний
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
        initial_msg = initial_msg .. "\n(Note: Auto-loaded core documentation: " .. table.concat(docs_loaded, ", ") .. ")"
    end

    -- 4. В последнюю очередь грузим целевой файл (Target File)
    if start_file then
        local norm_start = utils.normalize_path(config.PROJECT_ROOT, start_file)
        local content = utils.read_file_range(config.PROJECT_ROOT .. "/" .. norm_start)
        if content then
            ctx:add_file(norm_start, content)
            initial_msg = initial_msg .. "\n(Note: I loaded target file '"..norm_start.."' for you)"
        end
    end
    table.insert(ctx.chat_history, { role = "user", content = initial_msg })
end

local MAX_TURNS = 50
local turn = 0

local function enter_repl(ctx)
    while true do
        io.write("\n\27[34m[e-va shell]>\27[0m ")
        local user_input = io.read("*l")
        if not user_input or user_input == "exit" or user_input == "quit" then
            print("Exiting e-va. Goodbye.")
            os.remove(STATE_FILE)
            os.exit(0)
        elseif user_input ~= "" then
            table.insert(ctx.chat_history, { role = "user", content = user_input })
            return true
        end
    end
end

while turn < MAX_TURNS do
    turn = turn + 1
    utils.write_file(STATE_FILE, ctx:snapshot())

    if CURRENT_STATE == STATES.CODING then
        if ctx.execution_plan then
            for i, task in ipairs(ctx.execution_plan) do
                if task.file then
                    local fpath = task.file
                    if not ctx.knowledge_base[fpath] then
                        logger.info(string.format("Auto-loading plan file [%d/%d]", i, #ctx.execution_plan), fpath)
                        local full_path = config.PROJECT_ROOT .. "/" .. fpath
                        local content = utils.read_file_range(full_path)
                        if content then ctx:add_file(fpath, content) end
                    else
                        ctx:touch_file(fpath)
                    end
                end
            end
        end
    end

    local limits = config.LIMITS
    local available_tokens = limits.MAX_CONTEXT - limits.RESERVED_OUTPUT - limits.SYSTEM_PROMPT_ESTIMATE
    if available_tokens < 2000 then available_tokens = 4000 end

    local current_ratio = (CURRENT_STATE == STATES.CODING) and limits.MEMORY_RATIO or 0.5
    local memory_budget = math.floor(available_tokens * current_ratio)
    local chat_budget = available_tokens - memory_budget
    local memory_block = ctx:get_memory_block(memory_budget)

    local sys_prompt_text = ""
    if CURRENT_STATE == STATES.RESEARCH then sys_prompt_text = config.PROMPT_RESEARCH
    elseif CURRENT_STATE == STATES.PLANNING then sys_prompt_text = config.PROMPT_PLANNING
    elseif CURRENT_STATE == STATES.CODING then
        local task = ctx.execution_plan[ctx.current_task_index]
        sys_prompt_text = string.format(config.PROMPT_CODING_TEMPLATE,
            ctx.current_task_index, #ctx.execution_plan,
            task.file or "unknown", task.instruction or "unknown")
    end

    local identity_block = ctx:get_identity_prompt()
    local full_system_prompt = identity_block .. "\n" .. sys_prompt_text

    local digest_budget = math.floor(chat_budget * 0.2)
    local search_digest = ""

    if CURRENT_STATE == STATES.CODING then
        search_digest = ctx:get_search_digest(digest_budget)
    end

    local messages = {}
    local combined_system_prompt = full_system_prompt .. "\n\n" .. ctx:get_report(CURRENT_STATE) .. "\n\n" .. search_digest .. "\n\n" .. memory_block
    table.insert(messages, { role = "system", content = combined_system_prompt })

    local chat_buffer = {}
    local current_chat_cost = 0
    local history_len = #ctx.chat_history

    if history_len > 0 then
        for i = history_len, 1, -1 do
            local msg = ctx.chat_history[i]
            local content_str = msg.content or ""
            local cost = ctx:estimate_tokens(content_str)
            if (current_chat_cost + cost) < chat_budget then
                table.insert(chat_buffer, 1, msg)
                current_chat_cost = current_chat_cost + cost
            else break end
        end
    end

    for _, msg in ipairs(chat_buffer) do
        local safe_role = msg.role
        if safe_role == "system" then safe_role = "user" end
        table.insert(messages, { role = safe_role, content = msg.content })
    end

    local debug_dump = "=== SYSTEM ===\n" .. full_system_prompt .. "\n\n=== MEMORY ===\n" .. memory_block .. "\n\n=== CHAT HISTORY ===\n"
    for _, msg in ipairs(chat_buffer) do
        debug_dump = debug_dump .. string.format("[%s]: %s\n\n", string.upper(msg.role), msg.content or "")
    end
    logger.log_context(turn, CURRENT_STATE, debug_dump)

    local profile = (CURRENT_STATE == STATES.CODING) and config.LLM_MAIN or config.LLM_SCOUT
    logger.info(string.format("[TURN %d] Phase: %s", turn, CURRENT_STATE))
    io.write(string.format("\n\27[35m>>> AI (%s):\27[0m ", CURRENT_STATE))

    local response_data, err = llm.send_request(profile, messages, {
        on_token = function(t) io.write(t); io.flush() end
    })
    io.write("\n")

    if not response_data then
        logger.error("Network Error", err)
        break
    end

    local content = llm.extract_content(response_data) or ""
    table.insert(ctx.chat_history, { role = "assistant", content = content })
    logger.log_context(turn, CURRENT_STATE .. "_RESPONSE", content)

    local tool_out = ""
    local transition = false

    if CURRENT_STATE == STATES.PLANNING then
        local json_match = content:match("%[.*%]")
        if json_match then
             local status, plan = pcall(function() return json:decode(json_match) end)
             if status and plan and type(plan)=="table" and #plan > 0 then
                 for _, item in ipairs(plan) do
                     if item.file then item.file = utils.normalize_path(config.PROJECT_ROOT, item.file) end
                 end
                 ctx.execution_plan = plan
                 CURRENT_STATE = STATES.CODING
                 ctx.current_task_index = 1

                local first_task = ctx.execution_plan[1]

                 logger.info("Plan Approved. Engaging STRICT CODING Phase.")
                 table.insert(ctx.chat_history, {
                     role = "user",
                     content = string.format("EXECUTION PLAN APPROVED.\nSTRICT CODING MODE ENGAGED.\n[!] CRITICAL: Use the chat history above ONLY as reference. Do not converse. Output ONLY strict patch commands.\n\nSTARTING TASK 1/%d: %s\nInstruction: %s", #plan, first_task.file, first_task.instruction)
                 })
                 tool_out = "\n[SYSTEM]: Phase changed to CODING. Target file loaded."
                 transition = true
             end
        end
    end

    local cmds_executed = 0
    -- Инициализируем трекер состояния в контексте, если его еще нет
    ctx.last_cmd = ctx.last_cmd or ""
    ctx.cmd_loop_count = ctx.cmd_loop_count or 0

    for cmd in content:gmatch("<cmd>(.-)</cmd>") do
        cmds_executed = cmds_executed + 1
        
        -- [CIRCUIT BREAKER]: Детектор авторегрессивной петли
        if cmd == ctx.last_cmd then
            ctx.cmd_loop_count = ctx.cmd_loop_count + 1
        else
            ctx.last_cmd = cmd
            ctx.cmd_loop_count = 0
        end

        local res
        if ctx.cmd_loop_count >= 3 then
            -- Если команда повторяется 3-й раз подряд, рубим рубильник
            logger.warn("Agent Loop Detected. Injecting Pattern Breaker.", { command = cmd })
            res = { 
                output = "\n[SYSTEM FATAL ERROR]: AUTOREGRESSIVE LOOP DETECTED. You have issued the exact same command multiple times.\nSTOP READING. \nIf you know what to do, you MUST output EXACTLY <cmd>create_plan</cmd> immediately to proceed to the CODING phase. Do not repeat the previous action.", 
                signal = nil 
            }
            -- Сбрасываем счетчик, чтобы дать агенту шанс исправиться на следующем ходу
            ctx.cmd_loop_count = 0
        else
            -- Нормальное выполнение
            res = tool_executor.execute(cmd, ctx, CURRENT_STATE)
        end

        tool_out = tool_out .. (res.output or "")

        if res.signal == "TRANSITION_PLANNING" then
          CURRENT_STATE = STATES.PLANNING; transition = true
        elseif res.signal == "TASK_COMPLETE" then
            ctx.current_task_index = ctx.current_task_index + 1
            if ctx.current_task_index > #ctx.execution_plan then
                print("\n\27[32m>>> TASK COMPLETED. Returning to RESEARCH phase.\27[0m")
                CURRENT_STATE = STATES.RESEARCH
                table.insert(ctx.chat_history, { role = "user", content = "[SYSTEM]: Execution Plan fully completed. Awaiting new instructions." })
                enter_repl(ctx)
                turn = 0
                transition = true
            else
                local next_task = ctx.execution_plan[ctx.current_task_index]
                table.insert(ctx.chat_history, { 
                    role = "user", 
                    content = string.format("TASK %d COMPLETED.\nSTARTING TASK %d/%d: %s\nInstruction: %s", 
                        ctx.current_task_index - 1, ctx.current_task_index, #ctx.execution_plan, next_task.file, next_task.instruction) 
                })
            end
        end
    end

    if cmds_executed == 0 and CURRENT_STATE == STATES.RESEARCH then
        enter_repl(ctx)
        turn = 0
        transition = true
    end

    if tool_out ~= "" and not transition then
        table.insert(ctx.chat_history, { role = "user", content = tool_out })
    end
end
