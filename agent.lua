local config_module = require("config")
local utils = require("utils")
local llm = require("llm_handler")
local patcher = require("patcher")
local logger = require("logger")
local json = require("JSON")
local os = require("os")

local config = config_module.get()

local start_file = arg[1]
local instruction = arg[2]

if not instruction then
    print("Usage: eva [file_hint] \"<instruction>\"")
    os.exit(1)
end

-- === SYSTEM STATES ===
local STATES = {
    RESEARCH = "RESEARCH",
    PLANNING = "PLANNING",
    CODING = "CODING"
}
local CURRENT_STATE = STATES.RESEARCH

-- === MEMORY & CONTEXT ===
local KNOWLEDGE_BASE = {} -- Путь -> Контент
local FILE_STATES = {}    -- Путь -> Статус (READ, PATCHED)
local CHAT_HISTORY = {}   -- Список сообщений
local EXECUTION_PLAN = {} -- Список задач из фазы PLANNING
local CURRENT_TASK_INDEX = 1
local RECENT_HASHES = {}  -- Для детектора петель

-- === HELPER: Path Normalization ===
local function normalize_path_arg(p)
    if not p then return "" end
    local clean_p = utils.trim(p):gsub("^path=", ""):gsub("^file=", ""):gsub("['\"]", "")
    
    local path_part = clean_p
    local range_part = ""
    local s_idx = clean_p:find(":%D*%d+")
    if s_idx then
        path_part = clean_p:sub(1, s_idx - 1)
        range_part = clean_p:sub(s_idx)
    end

    local resolved = utils.resolve_relative_path(config.PROJECT_ROOT, path_part)
    return resolved .. range_part
end

-- === LOOP DETECTION ===
local function check_loop(content)
    -- Простейший хеш - сама строка (можно обрезать для экономии)
    local hash = content:sub(1, 100) .. (#content)
    local count = 0
    for _, h in ipairs(RECENT_HASHES) do
        if h == hash then count = count + 1 end
    end
    table.insert(RECENT_HASHES, hash)
    if #RECENT_HASHES > 5 then table.remove(RECENT_HASHES, 1) end
    return count
end

-- === CONTEXT BUILDER ===
local function get_memory_block()
    local mem = "\n\n=== MEMORY (OPEN FILES) ===\n"
    local count = 0
    for path, content in pairs(KNOWLEDGE_BASE) do
        count = count + 1
        local status = FILE_STATES[path] or "READ"
        -- Защита от переполнения: Если файл огромный, режем
        local display = content
        if #content > 12000 then
            display = content:sub(1, 4000) .. "\n...[SNIP: " .. (#content - 6000) .. " chars]...\n" .. content:sub(-2000)
        end
        mem = mem .. string.format("FILE (%s): %s\n```\n%s\n```\n", status, path, display)
    end
    if count == 0 then mem = mem .. "(No files loaded.)\n" end
    return mem
end

local function get_system_prompt()
    if CURRENT_STATE == STATES.RESEARCH then
        return config.PROMPT_RESEARCH
    elseif CURRENT_STATE == STATES.PLANNING then
        return config.PROMPT_PLANNING
    elseif CURRENT_STATE == STATES.CODING then
        local task = EXECUTION_PLAN[CURRENT_TASK_INDEX]
        if not task then return "ERROR: No task found." end
        return string.format(config.PROMPT_CODING_TEMPLATE, 
            CURRENT_TASK_INDEX, #EXECUTION_PLAN, 
            task.file or "Unknown", 
            task.instruction or "Unknown"
        )
    end
end

local function prune_history()
    -- Оставляем контекст "свежим". Держим около 20 сообщений.
    if #CHAT_HISTORY > 20 then
        local new_hist = {}
        table.insert(new_hist, CHAT_HISTORY[1]) -- Всегда помним главную задачу
        
        -- Оставляем последние 14 (7 пар запрос-ответ)
        local start_idx = #CHAT_HISTORY - 14
        if start_idx < 2 then start_idx = 2 end
        
        for i = start_idx, #CHAT_HISTORY do
            table.insert(new_hist, CHAT_HISTORY[i])
        end
        CHAT_HISTORY = new_hist
    end
end

-- === INITIALIZATION ===
local initial_msg = "TASK: " .. instruction
if start_file then
    logger.info("Pre-loading start file: " .. start_file)
    local rel_path = normalize_path_arg(start_file)
    local full_path = config.PROJECT_ROOT .. "/" .. rel_path
    local content = utils.read_file_range(full_path)
    if content then
        KNOWLEDGE_BASE[rel_path] = content
        FILE_STATES[rel_path] = "READ"
        initial_msg = initial_msg .. "\n(CONTEXT: File '" .. rel_path .. "' loaded into MEMORY.)"
    else
        logger.warn("Could not load start file: " .. full_path)
    end
end
table.insert(CHAT_HISTORY, { role = "user", content = initial_msg })

logger.info("System Initialized.", { root = config.PROJECT_ROOT })

-- === MAIN LOOP ===
local MAX_TURNS = 50
local turn = 0

while turn < MAX_TURNS do
    turn = turn + 1
    prune_history()

    local messages = {}
    table.insert(messages, { role = "system", content = get_system_prompt() })
    table.insert(messages, { role = "system", content = get_memory_block() })
    for _, msg in ipairs(CHAT_HISTORY) do table.insert(messages, msg) end

    -- Выбор профиля LLM
    local current_profile = config.LLM_MAIN
    local current_regex = config.REGEX_CODING 
    
    if CURRENT_STATE == STATES.RESEARCH then
        current_profile = config.LLM_SCOUT
        current_regex = config.REGEX_RESEARCH
    elseif CURRENT_STATE == STATES.PLANNING then
        current_profile = config.LLM_SCOUT
        current_regex = config.REGEX_PLANNING
    end

    logger.info(string.format("[TURN %d] Phase: %s", turn, CURRENT_STATE))

    local response_data, err = llm.send_request(current_profile, messages, {
        regex_pattern = current_regex
    })

    if not response_data then
        logger.error("Network Error: " .. (err or "unknown"))
        break
    end

    local raw_content = llm.extract_content(response_data) or ""
    local clean_response = llm.clean_code_blocks(raw_content)

    -- === VERBOSE LOGGING ===
    print("\n\27[35m>>> AI ("..CURRENT_STATE.."):\27[0m " .. raw_content .. (#raw_content > 300 and "..." or ""))
    table.insert(CHAT_HISTORY, { role = "assistant", content = raw_content })

    -- === LOOP CHECK ===
    local loop_hits = check_loop(clean_response)
    if loop_hits >= 2 then
        logger.warn("Loop detected (" .. loop_hits .. " hits)")
        if loop_hits >= 4 then
             table.insert(CHAT_HISTORY, { role = "user", content = "SYSTEM ALERT: You are repeating the same action. STOP. Change strategy." })
        end
    end

    local tool_output = ""
    local cmd_executed = false

    -- === STATE: RESEARCH ===
    if CURRENT_STATE == STATES.RESEARCH then
        for cmd in clean_response:gmatch("<cmd>(.-)</cmd>") do
            cmd_executed = true
            local action = utils.trim(cmd)
            print("\27[33m>>> CMD:\27[0m " .. action)

            if action == "list_files" then
                local listing = utils.list_files_recursive(config.PROJECT_ROOT)
                tool_output = tool_output .. "\n[LS]:\n" .. listing
                print("    -> Listed " .. select(2, listing:gsub('\n', '\n')) .. " files.")
            
            elseif action:match("^read_file:") then
                local raw_arg = action:match("^read_file:(.+)")
                local f_arg = normalize_path_arg(raw_arg)
                local path_only = f_arg:match("^([^:]+)") or f_arg
                
                if KNOWLEDGE_BASE[path_only] and not f_arg:find(":") then
                     tool_output = tool_output .. "\n[SYSTEM]: File '" .. path_only .. "' is already in MEMORY."
                     print("    -> Cached.")
                else
                    local read_arg = config.PROJECT_ROOT .. "/" .. f_arg
                    if f_arg:find(":") then -- Восстановление полного пути для диапазона
                        local suffix = f_arg:match("(:.+)")
                        read_arg = config.PROJECT_ROOT .. "/" .. path_only .. suffix
                    end
                    
                    local c = utils.read_file_range(read_arg)
                    if c then
                        if f_arg:find(":") then
                            tool_output = tool_output .. "\n[PARTIAL READ]:\n" .. c
                            print("    -> Partial read.")
                        else
                            KNOWLEDGE_BASE[path_only] = c
                            FILE_STATES[path_only] = "READ"
                            tool_output = tool_output .. "\n[SYSTEM]: File '" .. path_only .. "' loaded into MEMORY."
                            print("    -> Loaded " .. #c .. " bytes.")
                        end
                    else
                         tool_output = tool_output .. "\n[ERROR]: File not found: " .. path_only
                         print("    -> Error: Not found.")
                    end
                end

            elseif action:match("^search:") then
                local query = action:match("^search:(.+)")
                local grep_res = utils.grep_files(config.PROJECT_ROOT, query)
                tool_output = tool_output .. "\n[SEARCH RESULT]:\n" .. grep_res
                print("    -> Grep finished.")

            elseif action == "create_plan" then
                CURRENT_STATE = STATES.PLANNING
                tool_output = tool_output .. "\n[SYSTEM]: Phase -> PLANNING. Output JSON now."
                print(">>> TRANSITION: Research Complete.")
            end
        end

    -- === STATE: PLANNING ===
    elseif CURRENT_STATE == STATES.PLANNING then
        local json_start = clean_response:find("%[")
        if json_start then
             local potential_json = clean_response:sub(json_start)
             -- Пытаемся найти закрывающую скобку
             local json_end = potential_json:match(".*%](.*)")
             if json_end then 
                 potential_json = potential_json:sub(1, #potential_json - #json_end)
             end

             local plan, j_err = json:decode(potential_json)
             if plan and type(plan) == "table" and #plan > 0 then
                 EXECUTION_PLAN = plan
                 CURRENT_STATE = STATES.CODING
                 CURRENT_TASK_INDEX = 1
                 logger.info("Plan accepted", plan)
                 tool_output = tool_output .. "\n[SYSTEM]: Plan accepted. Switching to CODING. Starting Task 1."
                 cmd_executed = true
             else
                 tool_output = tool_output .. "\n[ERROR]: Invalid JSON. Please output ONLY the JSON list."
             end
        else
             tool_output = tool_output .. "\n[ERROR]: No JSON list found. Create the execution plan."
        end

    -- === STATE: CODING ===
    elseif CURRENT_STATE == STATES.CODING then
        if clean_response:match("<<<<<<< SEARCH") then
             local task = EXECUTION_PLAN[CURRENT_TASK_INDEX]
             local raw_file = clean_response:match("File:%s*([%w%./_%-]+)")
             local target_file = normalize_path_arg(raw_file or (task and task.file))
             
             if target_file and KNOWLEDGE_BASE[target_file] then
                 local ok, res, count = patcher.apply_search_replace(KNOWLEDGE_BASE[target_file], clean_response)
                 if ok then
                     if count == 0 then
                         tool_output = tool_output .. "\n[SYSTEM]: No changes needed (content matches)."
                     else
                         local w_ok, w_err = utils.write_file(config.PROJECT_ROOT .. "/" .. target_file, res)
                         if w_ok then
                             KNOWLEDGE_BASE[target_file] = res
                             FILE_STATES[target_file] = "PATCHED"
                             tool_output = tool_output .. "\n[SUCCESS]: File patched and saved."
                             print("\27[32m>>> PATCH APPLIED: " .. target_file .. "\27[0m")
                             
                             CURRENT_TASK_INDEX = CURRENT_TASK_INDEX + 1
                             if CURRENT_TASK_INDEX > #EXECUTION_PLAN then
                                 print("\27[32m>>> MISSION ACCOMPLISHED.\27[0m")
                                 os.exit(0)
                             else
                                 tool_output = tool_output .. "\n[SYSTEM]: Proceeding to Task " .. CURRENT_TASK_INDEX .. "..."
                             end
                         else
                             tool_output = tool_output .. "\n[DISK ERROR]: " .. tostring(w_err)
                         end
                     end
                 else
                     tool_output = tool_output .. "\n[PATCH ERROR]: " .. res
                 end
             else
                 tool_output = tool_output .. "\n[ERROR]: File not in memory. Read it first?"
             end
             cmd_executed = true
             
        elseif clean_response:match("<cmd>task_complete</cmd>") then
             CURRENT_TASK_INDEX = CURRENT_TASK_INDEX + 1
             if CURRENT_TASK_INDEX > #EXECUTION_PLAN then
                 print("\27[32m>>> MISSION ACCOMPLISHED.\27[0m")
                 os.exit(0)
             else
                 tool_output = tool_output .. "\n[SYSTEM]: Proceeding to Task " .. CURRENT_TASK_INDEX .. "..."
             end
             cmd_executed = true
        end
    end

    if not cmd_executed and tool_output == "" then
        -- Если модель просто "подумала" (есть Thinking), не ругаем её
        if not raw_content:match("Thinking:") then
            tool_output = "[SYSTEM]: Waiting for command. Status: " .. CURRENT_STATE
        end
    end

    if tool_output ~= "" then
        table.insert(CHAT_HISTORY, { role = "user", content = tool_output })
    end
end
