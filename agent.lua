-- agent.lua
local config = require("config").get()
local utils = require("utils")
local llm = require("llm_handler")
local patcher = require("patcher")

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
local KNOWLEDGE_BASE = {} -- path -> content
local FILE_STATES = {}    -- path -> "READ" | "PATCHED"
local CHAT_HISTORY = {}
local LAST_MSG_HASH = ""
local LOOP_COUNT = 0

local function normalize_path(p)
    return utils.trim(p):gsub("^%./", "")
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
        
        -- Truncation logic
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
    -- Нормализуем путь сразу
    local norm_path = normalize_path(start_file)
    local content = utils.read_file(norm_path)
    
    if content then
        -- 1. Кладём в память
        KNOWLEDGE_BASE[norm_path] = content
        -- 2. Ставим статус READ (прочитан)
        FILE_STATES[norm_path] = "READ"
        
        initial_msg = initial_msg .. "\n(CONTEXT: File '" .. norm_path .. "' is ALREADY loaded in memory. Look at the MEMORY block. Start analyzing it immediately.)"
    else
        print(">>> WARNING: Could not pre-load " .. start_file)
        initial_msg = initial_msg .. "\n(Hint: User pointed to '" .. start_file .. "', but I failed to read it. Please check it manually.)"
    end
end

table.insert(CHAT_HISTORY, { role = "user", content = initial_msg })

local turn = 0
local MAX_TURNS = 35 -- Чуть увеличили лимит

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
    
    -- Nudge (Пинки)
    local reminder = "CURRENT PHASE: " .. CURRENT_STATE .. "."
    if CURRENT_STATE == STATES.CODING then
        reminder = reminder .. " DO NOT re-read files you just patched. Trust your memory. Proceed to the next file."
    end
    table.insert(messages, { role = "system", content = reminder })

    print(string.format("\n[Turn %d | %s] Thinking...", turn, CURRENT_STATE))

    -- 2. LLM Request
    local payload = {
        model = config.API_MODEL,
        messages = messages,
        temperature = config.TEMPERATURE,
        max_tokens = 2048
    }
    
    local response_data = llm.send_request(payload)
    if not response_data then print("FATAL: Network error"); break end
    
    local raw_content = llm.extract_content(response_data) or ""
    local clean_response = llm.clean_code_blocks(raw_content)

    if not clean_response:match("<cmd>") and not clean_response:match("<<<<<<< SEARCH") then
        local lower = clean_response:lower()
        if lower:match("mission accomplished") or 
           lower:match("successfully completed") or 
           lower:match("all changes have been applied") then
            
            print(">>> DETECTED COMPLETION SPEECH. Auto-terminating.")
            print(">>> FINAL MESSAGE: " .. clean_response)
            os.exit(0)
        end
    end

    print(">>> RESP: " .. raw_content:sub(1, 150) .. "...") 
    table.insert(CHAT_HISTORY, { role = "assistant", content = raw_content })

    -- 3. Loop Protection
    if clean_response == LAST_MSG_HASH then
        LOOP_COUNT = LOOP_COUNT + 1
        print(">>> WARNING: Loop detected (" .. LOOP_COUNT .. ")")
        if LOOP_COUNT >= 2 then
            -- Injecting a user message to break the loop
            table.insert(CHAT_HISTORY, { role = "user", content = "SYSTEM ALERT: You are repeating yourself. STOP. If you finished the file, move to the next one. If you are done, output <cmd>finished</cmd>." })
        end
        if LOOP_COUNT > 4 then break end
    else
        LOOP_COUNT = 0
        LAST_MSG_HASH = clean_response
    end

    -- 4. Action Parsing
    local tool_output = ""
    local cmd_found = false

    -- Commands
    for cmd in clean_response:gmatch("<cmd>(.-)</cmd>") do
        cmd_found = true
        local action = utils.trim(cmd)
        print(">>> ACTION: " .. action)

        if action == "list_files" then
            tool_output = tool_output .. "\n[LS]:\n" .. utils.list_files_recursive(config.PROJECT_ROOT)
        
        elseif action:match("^read_file:") then
            local f = normalize_path(action:match("^read_file:(.+)"))
            
            -- SMART CACHE PROTECTION
            -- Если файл уже в памяти и мы в режиме кодинга, не даем читать его снова просто так
            if KNOWLEDGE_BASE[f] and CURRENT_STATE == STATES.CODING then
                 tool_output = tool_output .. "\n[SYSTEM]: File '" .. f .. "' is ALREADY in your memory (see above). DO NOT read it again. Apply your patch or move to the next file."
            else
                local c = utils.read_file(f)
                if c then
                    KNOWLEDGE_BASE[f] = c
                    FILE_STATES[f] = "READ"
                    tool_output = tool_output .. "\n[READ]: Loaded " .. f .. " (" .. #c .. " bytes)"
                else
                    tool_output = tool_output .. "\n[ERROR]: File not found " .. f
                end
            end

        elseif action:match("^map_file:") then
            local f = normalize_path(action:match("^map_file:(.+)"))
            if KNOWLEDGE_BASE[f] then
                 tool_output = tool_output .. "\n[SYSTEM]: File is already loaded. Look at the MEMORY block above."
            else
                local map = utils.get_file_outline(f)
                tool_output = tool_output .. "\n[MAP " .. f .. "]:\n" .. map
            end

        elseif action == "start_coding" then
            CURRENT_STATE = STATES.CODING
            tool_output = tool_output .. "\n[SYSTEM]: Phase switched to CODING. Focus on applying changes. Stop analyzing."

        elseif action == "finished" then
            print(">>> MISSION ACCOMPLISHED.")
            os.exit(0)
        end
    end

    -- Patches
    if CURRENT_STATE == STATES.CODING and clean_response:match("<<<<<<< SEARCH") then
        local target_file = clean_response:match("File:%s*([%w%./_%-]+)")
        if target_file then target_file = normalize_path(target_file) end

        if target_file and KNOWLEDGE_BASE[target_file] then
            print(">>> PATCHING: " .. target_file)
            local ok, res, count = patcher.apply_search_replace(KNOWLEDGE_BASE[target_file], clean_response)

            if ok then
                if count and count == 0 then
                    tool_output = tool_output .. "\n[SYSTEM]: Patch accepted, but NO CHANGES were needed (Search == Replace). Proceed to next file."
                else
                    utils.write_file(target_file, res)
                    KNOWLEDGE_BASE[target_file] = res
                    FILE_STATES[target_file] = "PATCHED"
                    tool_output = tool_output .. "\n[SUCCESS]: Patch applied to " .. target_file .. ". Proceed."
                end
                cmd_found = true
            else
                tool_output = tool_output .. "\n[PATCH ERROR]: " .. res
                cmd_found = true
            end
        else
            tool_output = tool_output .. "\n[ERROR]: You must read_file:" .. (target_file or "???") .. " before patching it."
            cmd_found = true
        end
    end

    if not cmd_found then
        tool_output = "[SYSTEM ERROR]: No command found. Use <cmd>...</cmd> or a PATCH block."
    end

    if tool_output ~= "" then
        table.insert(CHAT_HISTORY, { role = "user", content = tool_output })
    end
end
