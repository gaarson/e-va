-- agent.lua
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

-- === STATE MACHINE ===
local STATES = {
    RESEARCH = "RESEARCH",
    CODING = "CODING"
}
local CURRENT_STATE = STATES.RESEARCH

-- === MEMORY ===
local KNOWLEDGE_BASE = {} -- Key: relative_path, Value: content
local FILE_STATES = {}    -- Key: relative_path, Value: "READ" | "PATCHED"
local CHAT_HISTORY = {}
local LAST_MSG_HASH = ""
local LOOP_COUNT = 0

-- === HELPERS ===

-- Очищает аргументы от галлюцинаций модели (path=, ", ', filename=)
local function clean_command_arg(arg_str)
    if not arg_str then return "" end
    local s = utils.trim(arg_str)
    s = s:gsub("^path=", "")      -- убираем path=
    s = s:gsub("^filename=", "")  -- убираем filename=
    s = s:gsub("^file=", "")      -- убираем file=
    s = s:gsub("['\"]", "")       -- убираем кавычки
    return utils.trim(s)
end

local function normalize_path(p)
    -- Сначала чистим от мусора LLM
    local clean_p = clean_command_arg(p)
    
    if utils.resolve_relative_path then
        return utils.resolve_relative_path(config.PROJECT_ROOT, clean_p)
    else
        -- Fallback
        local clean = clean_p:gsub("^%./", "")
        local root_pattern = config.PROJECT_ROOT:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        clean = clean:gsub("^" .. root_pattern .. "/?", "")
        return clean
    end
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

-- === INITIALIZATION ===
local initial_msg = "TASK: " .. instruction

if start_file then
    print(">>> PRE-LOADING: " .. start_file)
    local rel_path = normalize_path(start_file)
    local full_path = config.PROJECT_ROOT .. "/" .. rel_path
    
    local content = utils.read_file(full_path)
    if content then
        KNOWLEDGE_BASE[rel_path] = content
        FILE_STATES[rel_path] = "READ"
        initial_msg = initial_msg .. "\n(CONTEXT: File '" .. rel_path .. "' is ALREADY loaded in MEMORY. DO NOT read it again.)"
    else
        print(">>> WARNING: Could not pre-load " .. full_path)
        initial_msg = initial_msg .. "\n(Hint: User pointed to '" .. rel_path .. "', but I failed to read it.)"
    end
end

table.insert(CHAT_HISTORY, { role = "user", content = initial_msg })

local turn = 0
local MAX_TURNS = 35

print(">>> E-VA INITIALIZED.")
print(">>> MODE: " .. CURRENT_STATE)

-- === MAIN LOOP ===
while turn < MAX_TURNS do
    turn = turn + 1
    
    -- 1. Prompt Building
    local messages = {}
    table.insert(messages, { role = "system", content = get_system_prompt() })
    table.insert(messages, { role = "system", content = get_context_block() })
    for _, msg in ipairs(CHAT_HISTORY) do table.insert(messages, msg) end
    
    local reminder = "CURRENT PHASE: " .. CURRENT_STATE .. "."
    if CURRENT_STATE == STATES.CODING then
        reminder = reminder .. " Focus on patching. Do not re-read files found in MEMORY."
    end
    table.insert(messages, { role = "system", content = reminder })

    print(string.format("\n[Turn %d | %s] Thinking...", turn, CURRENT_STATE))

    -- 2. Request
    local payload = {
        model = config.API_MODEL,
        messages = messages,
        temperature = 0.0,
        max_tokens = 2048
    }
    
    local response_data = llm.send_request(payload)
    if not response_data then print("FATAL: Network error"); break end
    
    local raw_content = llm.extract_content(response_data) or ""
    local clean_response = llm.clean_code_blocks(raw_content)

    print(">>> RESP: " .. raw_content:sub(1, 150) .. "...")
    table.insert(CHAT_HISTORY, { role = "assistant", content = raw_content })

    -- 3. Loop Protection
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

    -- 4. Auto-Exit
    if not clean_response:match("<cmd>") and not clean_response:match("<<<<<<< SEARCH") then
        local lower = clean_response:lower()
        if lower:match("mission accomplished") or 
           lower:match("successfully completed") or 
           lower:match("changes have been applied") then
            
            print(">>> DETECTED COMPLETION SPEECH. Auto-terminating.")
            os.exit(0)
        end
    end

    -- 5. Command Parsing
    local tool_output = ""
    local cmd_found = false

    for cmd in clean_response:gmatch("<cmd>(.-)</cmd>") do
        cmd_found = true
        local action = utils.trim(cmd)
        print(">>> ACTION: " .. action)

        if action == "list_files" then
            tool_output = tool_output .. "\n[LS]:\n" .. utils.list_files_recursive(config.PROJECT_ROOT)
        
        elseif action:match("^read_file:") then
            -- ЗАХВАТЫВАЕМ ВСЁ ПОСЛЕ ДВОЕТОЧИЯ
            local raw_arg = action:match("^read_file:(.+)")
            -- ЧИСТИМ ОТ path= И КАВЫЧЕК
            local f = normalize_path(raw_arg)
            
            if KNOWLEDGE_BASE[f] then
                 tool_output = tool_output .. "\n[SYSTEM]: File '" .. f .. "' is ALREADY in memory (see above). Use the content from MEMORY."
            else
                local full_read_path = config.PROJECT_ROOT .. "/" .. f
                local c = utils.read_file(full_read_path)
                if c then
                    KNOWLEDGE_BASE[f] = c
                    FILE_STATES[f] = "READ"
                    tool_output = tool_output .. "\n[READ]: Loaded " .. f .. " ("..#c.." bytes)"
                else
                    tool_output = tool_output .. "\n[ERROR]: File not found. Model asked for: '"..raw_arg.."', Normalized to: '"..f.."'. Check path."
                end
            end

        elseif action:match("^map_file:") then
             local raw_arg = action:match("^map_file:(.+)")
             local f = normalize_path(raw_arg)
             
             if KNOWLEDGE_BASE[f] then
                  tool_output = tool_output .. "\n[SYSTEM]: File is loaded. Check MEMORY block."
             else
                  local full_map_path = config.PROJECT_ROOT .. "/" .. f
                  local map = utils.get_file_outline(full_map_path)
                  tool_output = tool_output .. "\n[MAP " .. f .. "]:\n" .. map
             end

        elseif action == "start_coding" then
            CURRENT_STATE = STATES.CODING
            tool_output = tool_output .. "\n[SYSTEM]: Phase switched to CODING. You can now use SEARCH/REPLACE blocks."

        elseif action == "finished" then
            print(">>> MISSION ACCOMPLISHED.")
            os.exit(0)
        end
    end

    -- 6. Patching Logic
    if CURRENT_STATE == STATES.CODING and clean_response:match("<<<<<<< SEARCH") then
        local raw_file = clean_response:match("File:%s*([%w%./_%-]+)")
        -- Здесь тоже чистим, на случай если он напишет File: path=...
        local target_file = raw_file and normalize_path(raw_file)

        if target_file and KNOWLEDGE_BASE[target_file] then
            print(">>> PATCHING: " .. target_file)
            
            local ok, res, count = patcher.apply_search_replace(KNOWLEDGE_BASE[target_file], clean_response)
            
            if ok then
                if count and count == 0 then
                    tool_output = tool_output .. "\n[SYSTEM]: Patch valid, but NO CHANGES were needed (Search block == Replace block). Proceed to next file."
                else
                    local write_path = config.PROJECT_ROOT .. "/" .. target_file
                    local wrote_ok, w_err = utils.write_file(write_path, res)
                    
                    if wrote_ok then
                        KNOWLEDGE_BASE[target_file] = res
                        FILE_STATES[target_file] = "PATCHED"
                        tool_output = tool_output .. "\n[SUCCESS]: Saved changes to " .. target_file .. ". Proceed."
                    else
                         tool_output = tool_output .. "\n[DISK ERROR]: Could not write file: " .. tostring(w_err)
                    end
                end
                cmd_found = true
            else
                tool_output = tool_output .. "\n[PATCH ERROR]: " .. res
                cmd_found = true
            end
        else
            tool_output = tool_output .. "\n[ERROR]: Target file '" .. (target_file or "nil") .. "' not found in MEMORY. Read it first."
            cmd_found = true
        end
    end

    -- 7. Feedback Loop
    if not cmd_found then
        tool_output = "[SYSTEM ERROR]: No valid XML command or Patch block found."
    end
    if tool_output ~= "" then
        table.insert(CHAT_HISTORY, { role = "user", content = tool_output })
    end
end
