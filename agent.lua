local config = require("config").get()
local utils = require("utils")
local llm = require("llm_handler")
local patcher = require("patcher")
local os = require("os")

local start_file = arg[1]
local instruction = arg[2]

if not instruction then
    print("Usage: eva [file_hint] \"<instruction>\"")
    os.exit(1)
end

local STATES = {
    RESEARCH = "RESEARCH",
    CODING = "CODING"
}
local CURRENT_STATE = STATES.RESEARCH

local KNOWLEDGE_BASE = {}
local FILE_STATES = {}
local CHAT_HISTORY = {}
local LAST_MSG_HASH = ""
local LOOP_COUNT = 0

local function clean_command_arg(arg_str)
    if not arg_str then return "" end
    local s = utils.trim(arg_str)
    s = s:gsub("^path=", "")
    s = s:gsub("^filename=", "")
    s = s:gsub("^file=", "")
    s = s:gsub("['\"]", "")
    return utils.trim(s)
end

-- === FIX: Robust normalization ===
local function normalize_path_arg(p)
    local clean_p = clean_command_arg(p)
    
    -- Пытаемся отделить путь от диапазона.
    -- Ищем двоеточие, за которым (возможно через мусор) идут цифры
    local path_part = clean_p
    local range_part = ""
    
    local s_idx = clean_p:find(":%D*%d+")
    if s_idx then
        path_part = clean_p:sub(1, s_idx - 1)
        range_part = clean_p:sub(s_idx)
    end

    local resolved = ""
    if utils.resolve_relative_path then
        resolved = utils.resolve_relative_path(config.PROJECT_ROOT, path_part)
    else
        resolved = path_part:gsub("^%./", "")
        local root_pattern = config.PROJECT_ROOT:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        resolved = resolved:gsub("^" .. root_pattern .. "/?", "")
    end
    
    return resolved .. range_part
end

local function get_system_prompt()
    if CURRENT_STATE == STATES.RESEARCH then
        return config.PROMPT_RESEARCH
    else
        return config.PROMPT_CODING
    end
end

local function get_context_block()
    local mem = "\n\n=== MEMORY (OPEN FILES) ===\n"
    local count = 0
    for path, content in pairs(KNOWLEDGE_BASE) do
        count = count + 1
        local status = FILE_STATES[path] or "READ"
        local display = content

        if #content > 12000 then
            display = content:sub(1, 4000) .. "\n...[TRUNCATED: Use search to find details]...\n" .. content:sub(-3000)
        end

        mem = mem .. string.format("FILE (%s): %s\n```\n%s\n```\n", status, path, display)
    end
    if count == 0 then mem = mem .. "(No files loaded. Use read_file to load context)\n" end
    return mem
end

local initial_msg = "TASK: " .. instruction

if start_file then
    print(">>> PRE-LOADING: " .. start_file)
    local rel_path = normalize_path_arg(start_file)
    local full_path = config.PROJECT_ROOT .. "/" .. rel_path

    local content = utils.read_file_range(full_path)
    if content then
        KNOWLEDGE_BASE[rel_path] = content
        FILE_STATES[rel_path] = "READ"
        initial_msg = initial_msg .. "\n(CONTEXT: File '" .. rel_path .. "' is ALREADY loaded in MEMORY.)"
    else
        print(">>> WARNING: Could not pre-load " .. full_path)
    end
end

table.insert(CHAT_HISTORY, { role = "user", content = initial_msg })

local turn = 0
local MAX_TURNS = 35

print(">>> E-VA INITIALIZED.")
print(">>> MODE: " .. CURRENT_STATE)

while turn < MAX_TURNS do
    turn = turn + 1

    local messages = {}
    table.insert(messages, { role = "system", content = get_system_prompt() })
    table.insert(messages, { role = "system", content = get_context_block() })
    for _, msg in ipairs(CHAT_HISTORY) do table.insert(messages, msg) end

    local reminder = "CURRENT PHASE: " .. CURRENT_STATE .. "."
    if CURRENT_STATE == STATES.CODING then
        reminder = reminder .. " Focus on patching. Do not re-read files found in MEMORY. DO NOT use <cmd>patch</cmd>."
    end
    table.insert(messages, { role = "system", content = reminder })

    print(string.format("\n[Turn %d | %s] Thinking...", turn, CURRENT_STATE))

    local current_regex = nil
    if CURRENT_STATE == STATES.RESEARCH then
        current_regex = config.REGEX_RESEARCH
    else
        current_regex = config.REGEX_CODING
    end

    local response_data = llm.send_request(messages, {
        regex_pattern = current_regex
    })
    
    if not response_data then print("FATAL: Network error"); break end

    local raw_content = llm.extract_content(response_data) or ""
    local clean_response = llm.clean_code_blocks(raw_content)

    print(">>> RESP: " .. raw_content:sub(1, 150) .. "...")
    table.insert(CHAT_HISTORY, { role = "assistant", content = raw_content })

    if clean_response == LAST_MSG_HASH then
        LOOP_COUNT = LOOP_COUNT + 1
        print(">>> WARNING: Loop detected (" .. LOOP_COUNT .. ")")
        if LOOP_COUNT >= 2 then
             table.insert(CHAT_HISTORY, { role = "user", content = "SYSTEM ALERT: You are repeating yourself. STOP. If you finished the task, output <cmd>finished</cmd>." })
        end
        if LOOP_COUNT > 4 then break end
    else
        LOOP_COUNT = 0
        LAST_MSG_HASH = clean_response
    end

    if not clean_response:match("<cmd>") and not clean_response:match("<<<<<<< SEARCH") then
        local lower = clean_response:lower()
        if lower:match("mission accomplished") or
           lower:match("successfully completed") or
           lower:match("changes have been applied") then
            print(">>> DETECTED COMPLETION SPEECH. Auto-terminating.")
            os.exit(0)
        end
    end

    local tool_output = ""
    local cmd_found = false

    -- === COMMAND PARSING ===
    for cmd in clean_response:gmatch("<cmd>(.-)</cmd>") do
        cmd_found = true
        local action = utils.trim(cmd)
        print(">>> ACTION: " .. action)

        if action == "list_files" then
            tool_output = tool_output .. "\n[LS]:\n" .. utils.list_files_recursive(config.PROJECT_ROOT)

        elseif action:match("^read_file:") then
            local raw_arg = action:match("^read_file:(.+)")
            local f_arg = normalize_path_arg(raw_arg)
            
            -- Проверка на диапазон
            local is_range = f_arg:find(":%D*%d+") ~= nil
            local path_only = f_arg
            
            if is_range then
                local s_idx = f_arg:find(":%D*%d+")
                path_only = f_arg:sub(1, s_idx - 1)
            end

            if KNOWLEDGE_BASE[path_only] and not is_range then
                 tool_output = tool_output .. "\n[SYSTEM]: File '" .. path_only .. "' is ALREADY fully loaded."
            else
                local full_read_path = config.PROJECT_ROOT .. "/" .. (path_only)
                local read_arg = f_arg
                if is_range then
                     -- Формируем аргумент для utils (добавляем root к пути, но оставляем диапазон)
                     local s_idx = f_arg:find(":%D*%d+")
                     local range_suffix = f_arg:sub(s_idx)
                     read_arg = (config.PROJECT_ROOT .. "/" .. path_only) .. range_suffix
                end

                local c = utils.read_file_range(read_arg)
                
                if c then
                    if is_range then
                        tool_output = tool_output .. "\n[READ PARTIAL " .. f_arg .. "]:\n" .. c
                    else
                        KNOWLEDGE_BASE[f_arg] = c
                        FILE_STATES[f_arg] = "READ"
                        tool_output = tool_output .. "\n[READ FULL]: Loaded " .. f_arg .. " ("..#c.." bytes)"
                    end
                else
                    tool_output = tool_output .. "\n[ERROR]: File or Range not found: '"..read_arg.."'"
                end
            end

        elseif action:match("^map_file:") then
             local raw_arg = action:match("^map_file:(.+)")
             local f = normalize_path_arg(raw_arg)

             if KNOWLEDGE_BASE[f] then
                  tool_output = tool_output .. "\n[SYSTEM]: File is loaded. Check MEMORY block."
             else
                  local full_map_path = config.PROJECT_ROOT .. "/" .. f
                  local map = utils.get_file_outline(full_map_path)
                  tool_output = tool_output .. "\n[MAP " .. f .. "]:\n" .. map
             end

        elseif action == "start_coding" then
            CURRENT_STATE = STATES.CODING
            tool_output = tool_output .. "\n[SYSTEM]: Phase switched to CODING. You can now use SEARCH/REPLACE blocks. DO NOT use <cmd>patch</cmd>."

        elseif action == "finished" then
            print(">>> MISSION ACCOMPLISHED.")
            os.exit(0)
            
        elseif action:match("^patch:") then
             -- === CRITICAL FIX: Handle hallucinated patch command ===
             tool_output = tool_output .. "\n[SYSTEM ERROR]: <cmd>patch:...</cmd> is NOT a valid command. You must write the code block directly using the format:\nFile: ...\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE"
        end
    end

    -- 6. Patching Logic
    if CURRENT_STATE == STATES.CODING and clean_response:match("<<<<<<< SEARCH") then
        if not clean_response:match(">>>>>>> REPLACE") then
            tool_output = tool_output .. "\n[SYNTAX ERROR]: You started a '<<<<<<< SEARCH' block but didn't close it with '>>>>>>> REPLACE'. Please rewrite the COMPLETE block."
            cmd_found = true -- Считаем, что команда была, но ошибочная
        else
            local raw_file = clean_response:match("File:%s*([%w%./_%-]+)")
            -- Добавляем normalize, чтобы убрать лишнее
            local target_file = raw_file and normalize_path_arg(raw_file)

            if target_file and KNOWLEDGE_BASE[target_file] then
                print(">>> PATCHING: " .. target_file)
                local ok, res, count = patcher.apply_search_replace(KNOWLEDGE_BASE[target_file], clean_response)

                if ok then
                    if count and count == 0 then
                        tool_output = tool_output .. "\n[SYSTEM]: Patch valid, but NO CHANGES were needed (content matches). Proceed."
                    else
                        local write_path = config.PROJECT_ROOT .. "/" .. target_file
                        local wrote_ok, w_err = utils.write_file(write_path, res)

                        if wrote_ok then
                            KNOWLEDGE_BASE[target_file] = res
                            FILE_STATES[target_file] = "PATCHED"
                            tool_output = tool_output .. "\n[SUCCESS]: Saved changes to " .. target_file .. "."
                        else
                             tool_output = tool_output .. "\n[DISK ERROR]: Could not write file: " .. tostring(w_err)
                        end
                    end
                else
                    -- Важно: возвращаем ошибку патчера модели
                    tool_output = tool_output .. "\n[PATCH ERROR]: " .. res
                end
                cmd_found = true
            else
                tool_output = tool_output .. "\n[ERROR]: Target file '" .. (target_file or "nil") .. "' not found in MEMORY. Use read_file first."
                cmd_found = true
            end
        end
    end

    if not cmd_found then
        tool_output = "[SYSTEM ERROR]: No valid XML command or Patch block found."
    end
    if tool_output ~= "" then
        table.insert(CHAT_HISTORY, { role = "user", content = tool_output })
    end
end
