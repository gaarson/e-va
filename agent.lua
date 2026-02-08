-- agent.lua
local config = require("config").get()
local utils = require("utils")
local llm = require("llm_handler")
local patcher = require("patcher")

local start_file = arg[1]
local instruction = arg[2]

if not instruction then
    print("Usage: eva [file] \"<instruction>\"")
    os.exit(1)
end

-- === STATE ===
local KNOWLEDGE_BASE = {} 
local CHAT_HISTORY = {}
local LAST_TOOL_CMD = ""
local REPEAT_COUNT = 0

local function normalize_path(p)
    return utils.trim(p):gsub("^%./", "")
end

local function update_knowledge(path, content)
    KNOWLEDGE_BASE[normalize_path(path)] = content
end

local function get_memory_block()
    local mem = "\n\n=== OPEN FILES (CONTEXT) ===\n"
    local count = 0
    for path, content in pairs(KNOWLEDGE_BASE) do
        count = count + 1
        local display_content = content
        if #content > 8000 then
            display_content = content:sub(1, 8000) .. "\n...[TRUNCATED]..."
        end
        mem = mem .. string.format("FILE: %s\n```\n%s\n```\n", path, display_content)
    end
    if count == 0 then mem = mem .. "(None)\n" end
    return mem
end

-- Init
if start_file then
    local content = utils.read_file(start_file)
    if content then update_knowledge(start_file, content) end
end

table.insert(CHAT_HISTORY, { role = "user", content = "TASK: " .. instruction })

local MAX_TURNS = 20
local turn = 0

print(">>> AGENT INITIALIZED. Goal: " .. instruction)

while turn < MAX_TURNS do
    turn = turn + 1
    print(string.format("\n[Turn %d] Thinking...", turn))

    -- 1. Build Prompt
    local messages_payload = {}
    table.insert(messages_payload, { role = "system", content = config.SYSTEM_PROMPT })
    
    -- История диалога
    for _, msg in ipairs(CHAT_HISTORY) do table.insert(messages_payload, msg) end
    
    -- Память файлов
    table.insert(messages_payload, { role = "system", content = get_memory_block() })

    -- !!! ГЛАВНЫЙ ФИКС: Вставляем напоминание ПОСЛЕДНИМ сообщением !!!
    -- Это заставляет модель вернуть фокус на формат XML
    table.insert(messages_payload, { 
        role = "system", 
        content = "IMPORTANT: Do not explain your plan. Output ONLY the next <cmd>...<cmd> or a Patch block now." 
    })

    -- 2. LLM Request
    local payload = {
        model = config.API_MODEL,
        messages = messages_payload,
        temperature = config.TEMPERATURE,
        max_tokens = 2048
    }

    local response_data = llm.send_request(payload)
    if not response_data then print("FATAL: Network error."); break end
    
    local raw_content = llm.extract_content(response_data) or ""
    
    -- Debug Output
    print("---------------------------------------------------")
    print(">>> RAW LLM RESPONSE:\n" .. raw_content)
    print("---------------------------------------------------")

    local clean_response = llm.clean_code_blocks(raw_content)

    -- 3. Parse Actions
    local current_cmd = clean_response:match("<cmd>(.-)</cmd>")
    
    -- Fallback for Markdown blocks
    if not current_cmd then
        -- Иногда они пишут `read_file:test.lua`
        local backtick_cmd = clean_response:match("`([^`]+)`") 
        if backtick_cmd and (backtick_cmd:match("list_") or backtick_cmd:match("read_") or backtick_cmd:match("search_")) then
            current_cmd = backtick_cmd
        end
    end

    local tool_executed = false
    local tool_output = ""
    local force_stop = false

    -- Добавляем ответ ассистента в историю
    table.insert(CHAT_HISTORY, { role = "assistant", content = raw_content })

    if current_cmd and current_cmd == LAST_TOOL_CMD then
        REPEAT_COUNT = REPEAT_COUNT + 1
        print("\n>>> WARNING: Agent repeating command: " .. current_cmd)
        tool_output = "SYSTEM ERROR: You just executed this command. Check your plan and do something else."
        tool_executed = true
        if REPEAT_COUNT >= 4 then force_stop = true end
    else
        REPEAT_COUNT = 0
        LAST_TOOL_CMD = current_cmd or ""

        if current_cmd then
            local cmd_content = utils.trim(current_cmd)
            print("\n>>> EXEC: " .. cmd_content)

            if cmd_content:match("^read_file:") then
                local path = normalize_path(cmd_content:match("^read_file:(.+)"))
                if path:match("path/to") or path == "file" or path == "filename" then
                     tool_output = "SYSTEM ERROR: Use REAL filenames from list_files."
                elseif KNOWLEDGE_BASE[path] then
                     tool_output = "SYSTEM: File '"..path.."' is ALREADY open."
                else
                     local c = utils.read_file(config.PROJECT_ROOT.."/"..path)
                     if c then
                         update_knowledge(path, c)
                         tool_output = "SUCCESS: Read " .. path
                     else
                         tool_output = "ERROR: File not found: " .. path
                     end
                end
                tool_executed = true

            elseif cmd_content:match("^search_project:") then
                local pat = cmd_content:match("^search_project:(.+)")
                local res = utils.search_project(config.PROJECT_ROOT, pat)
                tool_output = "SEARCH RESULTS:\n" .. res
                tool_executed = true

            elseif cmd_content == "list_files" then
                local res = utils.list_files_recursive(config.PROJECT_ROOT)
                tool_output = "FILES TREE:\n" .. res
                tool_executed = true
            
            elseif cmd_content == "finished" then
                print("\n>>> TASK COMPLETED.")
                force_stop = true
            else
                tool_output = "SYSTEM ERROR: Unknown command format. Use <cmd>...</cmd>."
                tool_executed = true
            end
        end

        -- PATCH LOGIC
        if clean_response:match("<<<<<<< SEARCH") then
            print("\n>>> ATTEMPTING PATCH...")
            local explicit_file = clean_response:match("File:%s*([%w%./_%-]+)%s*\n*<<<<<<< SEARCH")
            if explicit_file then explicit_file = explicit_file:gsub("`", "") end

            local target_file = explicit_file
            if target_file and KNOWLEDGE_BASE[target_file] then
                print(">>> Target File: " .. target_file)
                local succ, res = patcher.apply_search_replace(KNOWLEDGE_BASE[target_file], clean_response)
                if succ then
                    utils.write_file(config.PROJECT_ROOT.."/"..target_file, res)
                    update_knowledge(target_file, res)
                    tool_output = tool_output .. "\nSUCCESS: Patched " .. target_file
                else
                    tool_output = tool_output .. "\nPATCH ERROR: " .. res
                end
            else
                 tool_output = tool_output .. "\nSYSTEM ERROR: You MUST write 'File: filename' immediately before '<<<<<<< SEARCH'."
            end
            tool_executed = true
        end
    end

    if force_stop then break end

    if tool_executed then
        if #tool_output > 6000 then tool_output = tool_output:sub(1, 6000) .. "\n...[TRUNCATED]" end
        table.insert(CHAT_HISTORY, { role = "user", content = tool_output })
    else
        print(">>> NO ACTION DETECTED. Nudging agent...")
        -- Жесткий пинок с примером
        table.insert(CHAT_HISTORY, { 
            role = "user", 
            content = "SYSTEM ERROR: You did not output a command. Output EXACTLY: <cmd>list_files</cmd> or <cmd>read_file:filename</cmd>." 
        })
    end
end
