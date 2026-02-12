local M = {}
local utils = require("utils")
local patcher = require("patcher")
local logger = require("logger")

function M.execute(action, context)
    local tool_output = ""
    local cmd_executed = true
    local config = context.config
    local KNOWLEDGE_BASE = context.kb
    local FILE_STATES = context.file_states
    local SEARCH_CACHE = context.search_cache

    if action == "list_files" then
        local listing = utils.list_files_recursive(config.PROJECT_ROOT)
        tool_output = "\n[LS]:\n" .. listing
        print("    -> Listed files.")

    elseif action:match("^read_file:") then
        local raw_arg = action:match("^read_file:(.+)")
        local f_arg = context.normalize_path(raw_arg)
        local path_only = f_arg:match("^([^:]+)") or f_arg

        -- === FIX: ВСЕГДА ВОЗВРАЩАЕМ КОНТЕНТ, ДАЖЕ ЕСЛИ ОН В КЭШЕ ===
        -- Это предотвращает цикл, когда LLM думает, что чтение не удалось
        if KNOWLEDGE_BASE[path_only] and not f_arg:find(":") then
             local content = KNOWLEDGE_BASE[path_only]
             -- Ограничиваем вывод, чтобы не забить контекст, если файл огромный
             local display = (#content > 12000) and (content:sub(1, 4000) .. "\n...[SNIP (File too large, use range)]...\n" .. content:sub(-2000)) or content
             
             tool_output = "\n[MEMORY READ (Refreshed)]:\n" .. display
             print("    -> Re-reading cached file.")
        else
            local read_arg = config.PROJECT_ROOT .. "/" .. f_arg
            if f_arg:find(":") then
                local suffix = f_arg:match("(:.+)")
                read_arg = config.PROJECT_ROOT .. "/" .. path_only .. suffix
            end
            local c = utils.read_file_range(read_arg)
            if c then
                if f_arg:find(":") then
                    tool_output = "\n[PARTIAL READ]:\n" .. c
                    print("    -> Partial read.")
                else
                    KNOWLEDGE_BASE[path_only] = c
                    FILE_STATES[path_only] = "READ"
                    tool_output = "\n[SYSTEM]: File loaded.\n" .. c
                    print("    -> Loaded " .. #c .. " bytes.")
                end
            else
                 tool_output = "\n[ERROR]: File not found: " .. path_only
                 print("    -> Error: Not found.")
            end
        end

    elseif action:match("^search:") then
        local query = utils.trim(action:match("^search:(.+)"))
        if SEARCH_CACHE[query] then
            tool_output = "\n[SYSTEM]: Cached result for '" .. query .. "':\n" .. SEARCH_CACHE[query]
            print("    -> Cached grep.")
        else
            local grep_res = utils.grep_files(config.PROJECT_ROOT, query)
            SEARCH_CACHE[query] = grep_res
            tool_output = "\n[SEARCH RESULT]:\n" .. grep_res
            print("    -> Grep finished.")
        end

    elseif action == "create_plan" then
        return { signal = "TRANSITION_PLANNING", output = "\n[SYSTEM]: Phase -> PLANNING. Output JSON now.", executed = true }

    elseif action == "task_complete" then
        return { signal = "TASK_COMPLETE", executed = true }

    else
        -- Жесткая ошибка на неизвестные команды, чтобы сбить галлюцинации
        print("\27[31m>>> UNKNOWN CMD:\27[0m " .. action)
        tool_output = "\n[SYSTEM ERROR]: Unknown command '" .. action .. "'. Allowed: read_file, search, task_complete."
        cmd_executed = true 
    end

    return { output = tool_output, executed = cmd_executed }
end

function M.try_apply_patch(llm_response, context)
    if not context.plan or not context.task_index then
        return false, "[SYSTEM ERROR]: Missing execution context."
    end

    local task = context.plan[context.task_index]
    local raw_file = llm_response:match("File:%s*([%w%./_%-]+)")
    local target_file = context.normalize_path(raw_file or (task and task.file))
    local output = ""

    if target_file and context.kb[target_file] then
        local ok, res, count = patcher.apply_search_replace(context.kb[target_file], llm_response)
        if ok then
            local w_ok, w_err = utils.write_file(context.config.PROJECT_ROOT .. "/" .. target_file, res)
            if w_ok then
                context.kb[target_file] = res
                context.file_states[target_file] = "PATCHED"
                output = "\n[SUCCESS]: Changes applied to " .. target_file
                print("\27[32m>>> PATCH APPLIED: " .. target_file .. "\27[0m")
            else
                output = "\n[DISK ERROR]: " .. tostring(w_err)
            end
        else
            logger.warn("Patch failed", res)
            output = "\n[PATCH ERROR]: SEARCH block mismatch.\nDetails: " .. res .. "\nACTION: Review MEMORY. Copy exact lines."
        end
        return true, output
    elseif target_file then
        return true, "\n[ERROR]: File '"..tostring(target_file).."' not in MEMORY. Read it first."
    end

    return false, ""
end

return M
