local config_module = require("config")
local utils = require("utils")
local llm = require("llm_handler")
local logger = require("logger")
local json = require("JSON")
local os = require("os")
local tool_executor = require("tool_executor")

local config = config_module.get()

-- === DEBUGGING ===
local DEBUG_LOG_PATH = config.PROJECT_ROOT .. "/_debug_context.log"
local f_init = io.open(DEBUG_LOG_PATH, "w")
if f_init then f_init:write("=== SESSION STARTED ===\n"); f_init:close() end

-- === STATE MANAGEMENT ===
local STATES = { RESEARCH = "RESEARCH", PLANNING = "PLANNING", CODING = "CODING" }
local CURRENT_STATE = STATES.RESEARCH
local KNOWLEDGE_BASE = {} -- Cache for file content
local FILE_STATES = {}    -- Status: READ, PATCHED
local FILE_ACCESS_RANK = {} -- LRU/Priority tracking
local GLOBAL_ACCESS_COUNTER = 0
local CHAT_HISTORY = {}
local EXECUTION_PLAN = {}
local CURRENT_TASK_INDEX = 1
local RECENT_HASHES = {}
local SEARCH_CACHE = {}
local HISTORY_CHECKPOINT = nil -- Snapshot after planning

local CONSECUTIVE_ERRORS = 0
local NO_OP_COUNTER = 0 -- Счетчик ходов без действий (только мысли)

-- === HELPER FUNCTIONS ===

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

local function touch_file(path)
    if not path then return end
    GLOBAL_ACCESS_COUNTER = GLOBAL_ACCESS_COUNTER + 1
    FILE_ACCESS_RANK[path] = GLOBAL_ACCESS_COUNTER
end

local function check_loop(content)
    -- Simple hash to detect identical repetitive outputs
    local hash = content:sub(1, 100) .. (#content)
    local count = 0
    for _, h in ipairs(RECENT_HASHES) do if h == hash then count = count + 1 end end
    table.insert(RECENT_HASHES, hash)
    if #RECENT_HASHES > 5 then table.remove(RECENT_HASHES, 1) end
    return count
end

local function get_memory_block()
    local files_list = {}
    for path, content in pairs(KNOWLEDGE_BASE) do
        table.insert(files_list, {
            path = path,
            content = content,
            rank = FILE_ACCESS_RANK[path] or 0
        })
    end
    -- Sort by rank (Last Accessed = Higher Priority)
    table.sort(files_list, function(a, b) return a.rank < b.rank end)

    local mem = "\n\n=== MEMORY (OPEN FILES - SORTED BY RELEVANCE) ===\n"
    local count = 0

    for _, f in ipairs(files_list) do
        count = count + 1
        local status = FILE_STATES[f.path] or "READ"
        -- Mark the very last touched file as CURRENT FOCUS
        local focus_marker = (count == #files_list) and " [CURRENT FOCUS]" or ""
        
        -- Smart truncation for context window management
        local display = (#f.content > 12000) and (f.content:sub(1, 4000) .. "\n...[SNIP]...\n" .. f.content:sub(-2000)) or f.content
        mem = mem .. string.format("FILE (%s)%s: %s\n```\n%s\n```\n", status, focus_marker, f.path, display)
    end
    return count == 0 and mem .. "(No files loaded.)\n" or mem
end

local function get_system_prompt()
    if CURRENT_STATE == STATES.RESEARCH then return config.PROMPT_RESEARCH
    elseif CURRENT_STATE == STATES.PLANNING then return config.PROMPT_PLANNING
    elseif CURRENT_STATE == STATES.CODING then
        local task = EXECUTION_PLAN[CURRENT_TASK_INDEX]
        -- === FIX APPLIED HERE ===
        return string.format(
            config.PROMPT_CODING_TEMPLATE, 
            CURRENT_TASK_INDEX, 
            #EXECUTION_PLAN, 
            task.file or "?", 
            task.instruction or "?",
            task.file or "?" -- Added this 5th argument
        )
    end
end

-- === MAIN ENTRY POINT ===

local start_file = arg[1]
local instruction = arg[2]
if not instruction then print("Usage: eva [file] \"<instruction>\""); os.exit(1) end

local initial_msg = "TASK: " .. instruction
if start_file then
    local rel = normalize_path_arg(start_file)
    local c = utils.read_file_range(config.PROJECT_ROOT .. "/" .. rel)
    if c then
        KNOWLEDGE_BASE[rel] = c
        touch_file(rel)
        initial_msg = initial_msg .. "\n(CONTEXT: Loaded '" .. rel .. "')"
    end
end
table.insert(CHAT_HISTORY, { role = "user", content = initial_msg })
logger.info("System Initialized.", { root = config.PROJECT_ROOT })

local MAX_TURNS = 50
local turn = 0

while turn < MAX_TURNS do
    turn = turn + 1

    -- 1. Construct Message Context
    local messages = {}
    table.insert(messages, { role = "system", content = get_system_prompt() })
    table.insert(messages, { role = "system", content = get_memory_block() })
    for _, msg in ipairs(CHAT_HISTORY) do table.insert(messages, msg) end

    -- 2. Select LLM Profile
    local current_profile = (CURRENT_STATE == STATES.RESEARCH or CURRENT_STATE == STATES.PLANNING) and config.LLM_SCOUT or config.LLM_MAIN

    logger.info(string.format("[TURN %d] Phase: %s", turn, CURRENT_STATE))

    -- 3. Execute Request
    io.write(string.format("\n\27[35m>>> AI (%s):\27[0m ", CURRENT_STATE))
    io.flush()

    local response_data, err = llm.send_request(current_profile, messages, {
        on_token = function(token)
            io.write(token)
            io.flush()
        end
    })
    io.write("\n")

    if not response_data then logger.error("Network Error: " .. (err or "?")); break end

    local raw_content = llm.extract_content(response_data) or ""
    table.insert(CHAT_HISTORY, { role = "assistant", content = raw_content })

    -- 4. Safety Checks
    if check_loop(llm.clean_code_blocks(raw_content)) >= 4 then
        table.insert(CHAT_HISTORY, { role = "user", content = "SYSTEM ALERT: STOP REPEATING. Change strategy." })
    end

    local tool_output = ""
    local cmd_executed = false
    local ctx = {
        config = config,
        kb = KNOWLEDGE_BASE,
        file_states = FILE_STATES,
        search_cache = SEARCH_CACHE,
        plan = EXECUTION_PLAN,
        task_index = CURRENT_TASK_INDEX,
        normalize_path = normalize_path_arg
    }

    -- === LOGIC HANDLERS ===

    -- A. APPLY PATCHES (Highest Priority)
    if CURRENT_STATE == STATES.CODING and raw_content:match("<<<<<<< SEARCH") then
        local patch_exec, patch_out = tool_executor.try_apply_patch(raw_content, ctx)
        if patch_exec then
            local patched_file = raw_content:match("File:%s*([%w%./_%-]+)")
            if patched_file then touch_file(ctx.normalize_path(patched_file)) end
            
            -- Feedback loop: Tell the model the patch succeeded, don't just exit.
            tool_output = tool_output .. patch_out .. "\n[SYSTEM]: Patch applied successfully. Please VERIFY the changes or output <cmd>task_complete</cmd> if fully done."
            
            cmd_executed = true
            CONSECUTIVE_ERRORS = 0 
        end
    end

    -- B. PLAN PARSING & CHECKPOINT
    if CURRENT_STATE == STATES.PLANNING then
        local json_match = raw_content:match("%[.*%]")
        if json_match then
            local plan, j_err = json:decode(json_match)
            if plan and type(plan) == "table" and #plan > 0 then
                EXECUTION_PLAN = plan
                CURRENT_STATE = STATES.CODING
                CURRENT_TASK_INDEX = 1
                logger.info("Plan accepted", plan)
                tool_output = tool_output .. "\n[SYSTEM]: Plan accepted. Switching to CODING phase."
                cmd_executed = true
                CONSECUTIVE_ERRORS = 0

                -- CREATE CHECKPOINT (Save only Research context)
                HISTORY_CHECKPOINT = {}
                for _, msg in ipairs(CHAT_HISTORY) do table.insert(HISTORY_CHECKPOINT, msg) end
                
                -- FORCE START FIRST TASK
                local first_task = EXECUTION_PLAN[1]
                if first_task.file then touch_file(ctx.normalize_path(first_task.file)) end
                
                -- Inject trigger for the first task
                table.insert(CHAT_HISTORY, { 
                    role = "user", 
                    content = string.format("STARTING TASK 1/%d.\nTarget: %s\nInstruction: %s\n\nREQUIRED: Start your response with a 'Thinking:' block to analyze the code, then provide the SEARCH/REPLACE block.", #EXECUTION_PLAN, first_task.file, first_task.instruction) 
                })

            else
                if #json_match > 10 then tool_output = tool_output .. "\n[ERROR]: Invalid JSON Plan." end
            end
        end
    end

    -- C. COMMAND EXECUTION
    for cmd in raw_content:gmatch("<cmd>(.-)</cmd>") do
        local action = utils.trim(cmd)
        print("\27[33m>>> CMD:\27[0m " .. action)

        local current_task_file = nil
        if EXECUTION_PLAN and EXECUTION_PLAN[CURRENT_TASK_INDEX] then
             current_task_file = EXECUTION_PLAN[CURRENT_TASK_INDEX].file
        end

        -- Блокируем SEARCH и чтение УЖЕ ЗАГРУЖЕННОГО целевого файла
        if CURRENT_STATE == STATES.CODING and (
            action:match("^search:") or 
            (action:match("^read_file:") and current_task_file and action:find(current_task_file, 1, true))
        ) then
             print("\27[31m>>> BLOCKED CMD:\27[0m Redundant action in CODING.")
             
             local hint = ""
             if action:match("^read_file") then
                 hint = "STOP READING. The file '"..current_task_file.."' is ALREADY in MEMORY above. JUST WRITE THE CODE."
             else
                 hint = "Search is disabled in CODING. Rely on the MEMORY block."
             end

             tool_output = tool_output .. "\n[SYSTEM ERROR]: " .. hint .. "\nACTION: Output the Thinking block and the SEARCH/REPLACE block immediately."
             cmd_executed = true
             CONSECUTIVE_ERRORS = CONSECUTIVE_ERRORS + 1

        else            -- Pre-processing for file reads
            if action:match("^read_file:") then
                local raw_arg = action:match("^read_file:(.+)")
                local path_only = ctx.normalize_path(raw_arg):match("^([^:]+)")
                touch_file(path_only)
            end

            local result = tool_executor.execute(action, ctx)
            
            if result.executed then
                cmd_executed = true
                CONSECUTIVE_ERRORS = 0
                tool_output = tool_output .. (result.output or "")

                if result.signal == "TRANSITION_PLANNING" then
                    CURRENT_STATE = STATES.PLANNING
                    print(">>> TRANSITION: Research Complete.")
                    break -- Break inner loop to refresh prompt immediately

                elseif result.signal == "TASK_COMPLETE" then
                    CURRENT_TASK_INDEX = CURRENT_TASK_INDEX + 1
                    
                    if CURRENT_TASK_INDEX > #EXECUTION_PLAN then
                        print("\27[32m>>> MISSION ACCOMPLISHED.\27[0m")
                        os.exit(0)
                    else
                        local next_task = EXECUTION_PLAN[CURRENT_TASK_INDEX]
                        
                        -- === CONTEXT SWITCHING LOGIC ===
                        -- Clear history to remove noise from previous task
                        CHAT_HISTORY = {} 
                        if HISTORY_CHECKPOINT then
                            for _, msg in ipairs(HISTORY_CHECKPOINT) do table.insert(CHAT_HISTORY, msg) end
                        end
                        
                        -- Force Touch the new target file to bring it to focus
                        if next_task.file then 
                            touch_file(ctx.normalize_path(next_task.file)) 
                        end

                        -- INJECT TRIGGER MESSAGE FOR THE MODEL
                        -- This prevents "lazy exit" by forcing a prompt that requires Thinking/Action
                        local trigger_msg = string.format(
                            "STARTING TASK %d/%d.\nTarget: %s\nInstruction: %s\n\nREQUIRED: Start your response with a 'Thinking:' block to analyze the code, then provide the SEARCH/REPLACE block.",
                            CURRENT_TASK_INDEX, #EXECUTION_PLAN, next_task.file or "?", next_task.instruction
                        )
                        
                        -- We add this as a USER message so the model feels compelled to answer it
                        table.insert(CHAT_HISTORY, { role = "user", content = trigger_msg })

                        tool_output = "\n[SYSTEM]: Context refreshed for next task."
                    end
                end
            end
        end
    end

    -- D. LOOP BREAKER
    if CONSECUTIVE_ERRORS >= 3 then
        local msg = "\n[SYSTEM ALERT]: You are stuck in a loop of invalid commands. STOP.\n1. Read the target file directly using <cmd>read_file:...</cmd>.\n2. Or output <cmd>task_complete</cmd> if you are confused."
        tool_output = tool_output .. msg
        print("\27[41;37m>>> LOOP INTERVENTION TRIGGERED \27[0m")
        CONSECUTIVE_ERRORS = 0
    end

    if cmd_executed then
        NO_OP_COUNTER = 0
    else
        NO_OP_COUNTER = NO_OP_COUNTER + 1
    end

    if NO_OP_COUNTER >= 2 then
        local instruction = EXECUTION_PLAN[CURRENT_TASK_INDEX].instruction
        
        local nudge_msg = string.format(
            "\n[SYSTEM INTERVENTION]: You have been thinking for %d turns without action.\n" ..
            "CHECK: If the file ALREADY matches the instruction '%s', you MUST output <cmd>task_complete</cmd> NOW.\n" ..
            "OTHERWISE: Output the <<<<<<< SEARCH block immediately.", 
            NO_OP_COUNTER, instruction
        )
        
        tool_output = tool_output .. nudge_msg
        print("\27[33m>>> NUDGING STALLED MODEL...\27[0m")
    elseif not cmd_executed and tool_output == "" then
        if raw_content:match("Thinking:") and not raw_content:match("<<<<<<< SEARCH") then
            tool_output = "[SYSTEM]: Good thought process. Now, if code changes are needed, Output the SEARCH/REPLACE block. If the code is ALREADY CORRECT, output <cmd>task_complete</cmd>."
        else
            tool_output = "[SYSTEM]: Waiting for command or code block."
        end
    end

    if tool_output ~= "" then
        table.insert(CHAT_HISTORY, { role = "user", content = tool_output })
    end
end
