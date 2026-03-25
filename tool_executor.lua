local M = {}
local utils = require("utils")
local patcher = require("patcher")
local logger = require("logger")
local os = require("os")

function M.execute(action, ctx, current_state)
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
            local content = utils.read_file_range(full_path)
            ctx:add_file(rel_path, content)
            output = "\n[SYSTEM]: Rollback successful for " .. rel_path
        else
            output = "\n[ERROR]: Rollback failed - " .. tostring(err)
        end

    elseif action == "cleanup_baks" then
        local ok = utils.cleanup_backups(config.PROJECT_ROOT)
        if ok then output = "\n[SYSTEM]: All .bak files removed." else output = "\n[ERROR]: Failed to clean up .bak files." end

    elseif action:match("^patch:") then
        local path, patch_body = action:match("^patch:([^%s\n]+)%s*\n(.*)")

        if not path or not patch_body then
            output = "\n[ERROR]: Invalid patch syntax. Use <cmd>patch:file\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n</cmd>"
        else
            local rel_path = utils.normalize_path(config.PROJECT_ROOT, path)
            local full_path = config.PROJECT_ROOT .. "/" .. rel_path

            if not ctx.knowledge_base[rel_path] then
                local content = utils.read_file_range(full_path)
                if content then ctx:add_file(rel_path, content)
                else return { output = "\n[ERROR] File not found on disk: " .. rel_path, signal = nil } end
            end

            local ok, new_content, changes, err_msg = patcher.apply_patch(ctx.knowledge_base[rel_path], patch_body)

            if ok then
                utils.copy_file(full_path, full_path .. ".bak")
                local w_ok, w_err = utils.write_file(full_path, new_content)
                if w_ok then
                    ctx:add_file(rel_path, new_content)
                    output = string.format("\n[SUCCESS]: Applied %d patch block(s) to %s. PLEASE CHECK MEMORY ABOVE.", changes, rel_path)
                    signal = "MUTATION_SUCCESS"
                else
                    output = "\n[DISK ERROR]: " .. tostring(w_err)
                end
            else
                output = "\n[PATCH FAILED]: " .. tostring(err_msg) .. "\nEnsure EXACT match with Memory block. Are you editing the CORRECT file?"
            end
        end

    elseif action:match("^create_file:") then
        local path, new_code = action:match("^create_file:([^%s]+)%s*\n(.*)")

        if not path then
            output = "\n[ERROR]: Invalid create_file syntax. Use <cmd>create_file:path/to/file\n[code]</cmd>"
        else
            local rel_path = utils.normalize_path(config.PROJECT_ROOT, path)
            local full_path = config.PROJECT_ROOT .. "/" .. rel_path

            if utils.read_file_range(full_path) then
                utils.copy_file(full_path, full_path .. ".bak")
            end

            local dir_path = full_path:match("^(.*)/[^/]+$")
            if dir_path and dir_path ~= "" then
                os.execute("mkdir -p '" .. dir_path .. "' 2>/dev/null")
            end

            local ok, err = utils.write_file(full_path, new_code or "")

            if ok then
                ctx:add_file(rel_path, new_code or "")
                output = string.format("\n[SUCCESS]: Created/Overwritten file %s.", rel_path)
                signal = "MUTATION_SUCCESS"
            else
                output = "\n[ERROR]: " .. tostring(err)
            end
        end

    elseif action:match("^shell:") then
        local cmd = action:match("^shell:(.+)")
        cmd = utils.trim(cmd)

        local safe_prefixes = { "ls", "cat", "grep", "rg", "echo", "pwd", "ps", "find", "head", "tail", "whoami" }
        local is_safe = false
        for _, prefix in ipairs(safe_prefixes) do
            if cmd:match("^" .. prefix .. "%s") or cmd == prefix then is_safe = true; break end
        end

        if not is_safe then
            io.write(string.format("\n\27[31m[SECURITY WARNING]\27[0m AI wants to execute: \27[33m%s\27[0m\n", cmd))
            io.write("Allow execution? [y/N]: ")
            local ans = io.read("*l")

            if not ans or ans:lower() ~= "y" then
                return { output = "\n[SYSTEM]: Command execution DENIED by user. Do not try this command again.", signal = nil }
            end
        end

        -- Выполняем команду
        local f = io.popen(cmd .. " 2>&1")
        if f then
            local res = f:read("*a")
            f:close()
            if #res == 0 then res = "(Command executed silently)" end
            if #res > 4000 then res = res:sub(1, 4000) .. "\n...[TRUNCATED]" end
            output = "\n[SHELL STDOUT/STDERR]:\n" .. res

            -- [CIRCUIT BREAKER]: Отслеживание падающих тестов
            ctx.test_failures = ctx.test_failures or 0
            if cmd:match("test") or cmd:match("make") or cmd:match("check") or cmd:match("build") then
                if res:match("[Ee]rror") or res:match("[Ff]ail") or res:match("command not found") then
                    ctx.test_failures = ctx.test_failures + 1
                    if ctx.test_failures >= 3 then
                        output = output .. "\n\n[CIRCUIT BREAKER TRIGGERED]: You have failed this shell validation 3 times in a row. STOP BLIND PATCHING. Read the actual error and use <cmd>read_chunk</cmd> to verify the source code before trying again."
                        ctx.test_failures = 0
                    end
                else
                    ctx.test_failures = 0
                end
            end
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

return M
