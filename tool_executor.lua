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

        if ctx.knowledge_base[rel_path] then
             output = "\n[SYSTEM]: File '" .. rel_path .. "' is ALREADY loaded in memory. Skipping read."
        else
            local full_path = config.PROJECT_ROOT .. "/" .. rel_path
            local content, err = utils.read_file_range(full_path)
            if content then
                ctx:add_file(rel_path, content)
                output = "\n[SYSTEM]: Loaded " .. rel_path
            else
                output = "\n[ERROR]: " .. tostring(err)
            end
        end

    elseif action:match("^search:") then
        local query = action:match("^search:(.+)")
        if not query or utils.trim(query) == "" then
            output = "\n[ERROR]: Empty search query."
        elseif ctx:has_searched(query) then
            output = "\n[SYSTEM]: Skipped duplicate search. Check History."
        else
            local safe_query = utils.shell_quote(query)
            local safe_root = utils.shell_quote(config.PROJECT_ROOT)
            local cmd = string.format("rg -n -i -C 1 --color never --fixed-strings --glob '!.git/' %s %s 2>&1 | head -c 4000", safe_query, safe_root)
            local f = io.popen(cmd)
            local res = f:read("*a") or ""
            f:close()
            if #res == 0 then res = "(No matches found)"
            elseif #res >= 4000 then res = res .. "\n...(Truncated)..." end
            ctx:add_search_result(query, res)
            output = "\n[SEARCH RESULTS for '"..query.."']:\n" .. res
        end

    elseif action:match("^read_chunk:") then
        local args = action:match("^read_chunk:(.+)")
        local path, start_l, end_l = args:match("^(.-):(%d+)%-(%d+)$")
        if not path then path, start_l, end_l = args:match("^path:(.-):(%d+)%-(%d+)$") end

        if path then
            local rel = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            local full = ctx.config.PROJECT_ROOT .. "/" .. rel
            local content, total = utils.read_file_numbered(full, tonumber(start_l), tonumber(end_l))
            if content then
                output = string.format("\n[SYSTEM] Chunk of '%s' (Lines %s-%s):\n```\n%s\n```", rel, start_l, end_l, content)
            else
                output = "[ERROR] Could not read chunk: " .. rel
            end
        else
            output = "[ERROR] Usage: read_chunk:filename:start-end"
        end
    elseif action:match("^rollback:") then
        local raw_arg = action:match("^rollback:(.+)")
        local rel_path = utils.normalize_path(config.PROJECT_ROOT, raw_arg)
        local full_path = config.PROJECT_ROOT .. "/" .. rel_path
        
        local ok, err = utils.restore_backup(full_path)
        if ok then
            -- Обновляем контекст памяти, чтобы агент увидел старый код
            local content = utils.read_file_range(full_path)
            ctx:add_file(rel_path, content)
            output = "\n[SYSTEM]: Rollback successful for " .. rel_path
        else
            output = "\n[ERROR]: Rollback failed - " .. tostring(err)
        end

    elseif action == "cleanup_baks" then
        local ok = utils.cleanup_backups(config.PROJECT_ROOT)
        if ok then
            output = "\n[SYSTEM]: All .bak files removed."
        else
            output = "\n[ERROR]: Failed to clean up .bak files."
        end

    -- tool_executor.lua (дополнения)

    elseif action:match("^shell:") then
        local cmd = action:match("^shell:(.+)")
        -- ВНИМАНИЕ: Выполнение shell-команд от LLM требует осторожности.
        -- В production здесь должен быть whitelist или запуск в sandbox.
        local f = io.popen(cmd .. " 2>&1")
        if f then
            local res = f:read("*a")
            f:close()
            if #res == 0 then res = "(Command executed silently)" end
            -- Ограничиваем вывод, чтобы не переполнить контекст LLM (например, выхлоп dmesg)
            if #res > 4000 then res = res:sub(1, 4000) .. "\n...[TRUNCATED]" end
            output = "\n[SHELL STDOUT/STDERR]:\n" .. res
        else
            output = "\n[ERROR]: Failed to spawn shell process."
        end

    elseif action:match("^set_persona:") then
        local new_persona = action:match("^set_persona:(.+)")
        if ctx.identity then
            ctx.identity.persona = require("utils").trim(new_persona)
            output = "\n[SYSTEM]: Interface/Persona dynamically changed to: " .. ctx.identity.persona
        else
            output = "\n[ERROR]: Identity context not initialized."
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
    
    -- 1. Extract file explicitly declared by LLM
    local raw_file = llm_response:match("File:%s*([%w%./_%-:/]+)")
    local declared_file = raw_file and utils.normalize_path(ctx.config.PROJECT_ROOT, raw_file)

    -- 2. Determine Expected File from Plan
    local expected_file = nil
    if task and task.file then
        expected_file = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)
    end

    -- 3. VALIDATION: Prevent Hallucination of wrong files
    if declared_file and expected_file then
        -- Simple check: ends with same name (handle potential ./ prefix diffs)
        if declared_file ~= expected_file then
            return false, string.format("[SAFETY LOCK] You are trying to edit '%s', but the current Task Plan is for '%s'. Stick to the plan!", declared_file, expected_file)
        end
    end

    -- Fallback for legacy behavior
    local target_file = declared_file or expected_file

    if not target_file then
        return false, "[ERROR] Unknown target file. Response must start with 'File: path/to/file'."
    end

    if not ctx.knowledge_base[target_file] then
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. target_file
        local content = utils.read_file_range(full_path)
        if content then ctx:add_file(target_file, content)
        else return false, "[ERROR] File not found on disk: " .. target_file end
    end

    local ok, new_content, changes, err_msg = patcher.apply_patch(ctx.knowledge_base[target_file], llm_response)

    if ok then
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. target_file
        
        local bak_ok, bak_err = utils.copy_file(full_path, full_path .. ".bak")
        if not bak_ok then
            logger.warn("Backup creation failed", bak_err)
        end

        local w_ok, w_err = utils.write_file(full_path, new_content)
        if w_ok then
            ctx:add_file(target_file, new_content)
            return true, string.format("\n[SUCCESS] Applied %d changes to %s.", changes, target_file)
        else
            return false, "[DISK ERROR] " .. tostring(w_err)
        end
    else
        return false, tostring(err_msg)
    end
end

return M
