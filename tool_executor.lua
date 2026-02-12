local M = {}
local utils = require("utils")
local patcher = require("patcher")
local logger = require("logger")
local os = require("os")

function M.execute(action, ctx)
    local config = ctx.config
    local output = ""
    local signal = nil

    if action == "list_files" then
        ctx.file_tree = utils.list_files_recursive(config.PROJECT_ROOT)
        output = "\n[SYSTEM]: File tree updated."
    
    elseif action:match("^read_file:") then
        local raw_arg = action:match("^read_file:(.+)")
        local rel_path = utils.normalize_path(config.PROJECT_ROOT, raw_arg)
        local full_path = config.PROJECT_ROOT .. "/" .. rel_path
        local content, err = utils.read_file_range(full_path)
        if content then
            ctx:add_file(rel_path, content)
            output = "\n[SYSTEM]: Loaded " .. rel_path
        else
            output = "\n[ERROR]: " .. tostring(err)
        end

    elseif action == "create_plan" then
        output = "PLANNING_PHASE"
        signal = "TRANSITION_PLANNING"

    elseif action == "task_complete" then
        signal = "TASK_COMPLETE"
    end

    return { output = output, signal = signal }
end

function M.try_apply_patch(llm_response, ctx)
    local task = ctx.execution_plan[ctx.current_task_index]
    
    local raw_file = llm_response:match("File:%s*([%w%./_%-]+)")
    local target_file = raw_file and utils.normalize_path(ctx.config.PROJECT_ROOT, raw_file)
    if not target_file and task then target_file = task.file end

    if not target_file then
        return false, "[ERROR] Unknown target file."
    end

    if not ctx.knowledge_base[target_file] then
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. target_file
        local content = utils.read_file_range(full_path)
        if content then 
            ctx:add_file(target_file, content) 
        else
            return false, "[ERROR] File not found on disk: " .. target_file
        end
    end

    local ok, new_content, changes = patcher.apply_search_replace(ctx.knowledge_base[target_file], llm_response)

    if ok then
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. target_file
        
        -- 1. BACKUP (Lua 5.1 os.execute logic)
        -- os.execute возвращает 0 при успехе в POSIX (Linux/Mac)
        local cp_cmd = string.format("cp '%s' '%s.bak'", full_path, full_path)
        os.execute(cp_cmd) 
        
        -- 2. WRITE
        local w_ok, w_err = utils.write_file(full_path, new_content)
        if w_ok then
            -- 3. UPDATE CONTEXT
            ctx:add_file(target_file, new_content) 
            return true, string.format("\n[SUCCESS] Applied %d changes to %s. Backup created.", changes, target_file)
        else
            return false, "[DISK ERROR] " .. tostring(w_err)
        end
    else
        return true, "[PATCH ERROR] " .. new_content 
    end
end

return M
