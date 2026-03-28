local registry = require("tool_registry")
local utils = require("utils")
local patcher = require("patcher")
local json = require("JSON")
local logger = require("logger")
local os = require("os")

local function init_core_tools()
    registry.register("list_files", "Lists all files in project", function(args, ctx, agent_name)
        ctx.file_tree = utils.list_files_recursive(ctx.config.PROJECT_ROOT)
        return { output = "\n[SYSTEM]: File tree updated." }
    end)

    registry.register("read_file", "Loads full file into memory", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        if ctx.knowledge_base[rel_path] then
             return { output = "\n[SYSTEM]: File '" .. rel_path .. "' is ALREADY in memory." }
        else
            local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
            local content, err = utils.read_file_range(full_path)
            if content then
                ctx:add_file(rel_path, content)
                return { output = "\n[SYSTEM]: Loaded " .. rel_path }
            else
                return { output = "\n[ERROR]: " .. tostring(err) }
            end
        end
    end)

    registry.register("read_chunk", "Reads specific lines", function(args, ctx, agent_name)
        local path, start_l, end_l = args:match("^(.-):(%d+)%-(%d+)$")
        if not path then path, start_l, end_l = args:match("^path:(.-):(%d+)%-(%d+)$") end

        if path then
            local rel = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            local full = ctx.config.PROJECT_ROOT .. "/" .. rel
            local content, total = utils.read_file_numbered(full, tonumber(start_l), tonumber(end_l))
            if content then
                return { output = string.format("\n[SYSTEM] Chunk of '%s' (Lines %s-%s):\n```\n%s\n```", rel, start_l, end_l, content) }
            else
                return { output = "[ERROR] Could not read chunk: " .. rel }
            end
        else
            return { output = "[ERROR] Usage: read_chunk:filename:start-end" }
        end
    end)

    registry.register("search", "Fast RipGrep search", function(args, ctx, agent_name)
        local query = utils.trim(args)
        if query == "" then return { output = "\n[ERROR]: Empty search query." } end
        if ctx:has_searched(query) then return { output = "\n[SYSTEM]: Skipped duplicate search. Check History." } end

        local safe_query = utils.shell_quote(query)
        local safe_root = utils.shell_quote(ctx.config.PROJECT_ROOT)
        local cmd = string.format("rg -n -i -C 1 --color never --fixed-strings --glob '!.git/' %s %s 2>&1 | head -c 4000", safe_query, safe_root)
        local f = io.popen(cmd)
        local res = f:read("*a") or ""
        f:close()

        if #res == 0 then res = "(No matches found)"
        elseif #res >= 4000 then res = res .. "\n...(Truncated)..." end
        ctx:add_search_result(query, res)
        return { output = "\n[SEARCH RESULTS for '"..query.."']:\n" .. res }
    end)

    registry.register("rollback", "Restores file from .bak", function(args, ctx, agent_name)
        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, args)
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
        local ok, err = utils.restore_backup(full_path)
        if ok then
            local content = utils.read_file_range(full_path)
            ctx:add_file(rel_path, content)
            return { output = "\n[SYSTEM]: Rollback successful for " .. rel_path }
        else
            return { output = "\n[ERROR]: Rollback failed - " .. tostring(err) }
        end
    end)

    registry.register("cleanup_baks", "Deletes all .bak files", function(args, ctx, agent_name)
        local ok = utils.cleanup_backups(ctx.config.PROJECT_ROOT)
        if ok then return { output = "\n[SYSTEM]: All .bak files removed." }
        else return { output = "\n[ERROR]: Failed to clean up .bak files." } end
    end)

    registry.register("patch", "Applies diffs to code", function(args, ctx, agent_name)
        local path, patch_body = args:match("^([^%s\n]+)%s*\n(.*)")
        if not path or not patch_body then
            return { output = "\n[ERROR]: Invalid patch syntax. Use <cmd>patch:file\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n</cmd>" }
        end

        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path

        if not ctx.knowledge_base[rel_path] then
            local content = utils.read_file_range(full_path)
            if content then ctx:add_file(rel_path, content)
            else return { output = "\n[ERROR] File not found on disk: " .. rel_path } end
        end

        local ok, new_content, changes, err_msg = patcher.apply_patch(ctx.knowledge_base[rel_path], patch_body)

        if ok then
            utils.copy_file(full_path, full_path .. ".bak")
            local w_ok, w_err = utils.write_file(full_path, new_content)
            if w_ok then
                ctx:add_file(rel_path, new_content)
                ctx:squash_last_mutation(agent_name)
                return { output = string.format("\n[SUCCESS]: Applied %d patch block(s) to %s.", changes, rel_path), signal = "MUTATION_SUCCESS" }
            else
                return { output = "\n[DISK ERROR]: " .. tostring(w_err) }
            end
        else
            return { output = "\n[PATCH FAILED]: " .. tostring(err_msg) }
        end
    end)

    registry.register("create_file", "Creates or overwrites a file", function(args, ctx, agent_name)
        local path, new_code = args:match("^([^%s]+)%s*\n(.*)")
        if not path then
            return { output = "\n[ERROR]: Invalid create_file syntax. Use <cmd>create_file:path/to/file\n[code]</cmd>" }
        end

        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path

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
            ctx:squash_last_mutation(agent_name)
            return { output = string.format("\n[SUCCESS]: Created/Overwritten file %s.", rel_path), signal = "MUTATION_SUCCESS" }
        else
            return { output = "\n[ERROR]: " .. tostring(err) }
        end
    end)

    registry.register("shell", "Executes shell commands with streaming output and timeouts", function(args, ctx, agent_name)
        local cmd = utils.trim(args)
        local safe_prefixes = { "ls", "cat", "grep", "rg", "echo", "pwd", "ps", "find", "head", "tail", "whoami", "make", "test" }
        local is_safe = false
        
        for _, prefix in ipairs(safe_prefixes) do
            if cmd:match("^" .. prefix .. "%s") or cmd == prefix then is_safe = true; break end
        end

        if not is_safe then
            io.write(string.format("\n\27[31m[SECURITY WARNING]\27[0m Agent '%s' wants to execute: \27[33m%s\27[0m\n", agent_name, cmd))
            io.write("Allow execution? [y/N]: ")
            local ans = io.read("*l")
            if not ans or ans:lower() ~= "y" then
                return { output = "\n[SYSTEM]: Command execution DENIED by user. Do not try this command again." }
            end
        end

        print(string.format("\n\27[34m[SYSTEM: Executing '%s']\27[0m", cmd))

        local tmp_file = os.tmpname()
        local exit_file = tmp_file .. ".exit_code"

        local wrapper_script = string.format(
            "timeout 600 bash -c %s > '%s' 2>&1; echo $? > '%s'",
            utils.shell_quote(cmd), tmp_file, exit_file
        )

        os.execute(wrapper_script .. " &")

        local output_chunks = {}
        local last_pos = 0
        local exit_code = nil

        while true do
            local f = io.open(tmp_file, "rb")
            if f then
                f:seek("set", last_pos)
                local chunk = f:read("*a")
                if chunk and #chunk > 0 then
                    io.write("\27[90m" .. chunk .. "\27[0m")
                    io.flush()
                    table.insert(output_chunks, chunk)
                    last_pos = f:seek()
                end
                f:close()
            end

            local f_code = io.open(exit_file, "r")
            if f_code then
                local code_str = f_code:read("*a")
                if code_str and #code_str > 0 then
                    exit_code = tonumber(utils.trim(code_str))
                    f_code:close()
                    break
                end
                f_code:close()
            end

            os.execute("sleep 0.1")
        end

        print("\27[34m[SYSTEM: Execution finished]\27[0m")

        os.remove(tmp_file)
        os.remove(exit_file)

        local res = table.concat(output_chunks)
        if #res == 0 then 
            res = "(Command executed silently. Status: " .. tostring(exit_code or 0) .. ")" 
        end
        
        -- [SMART TRUNCATION]: Оставляем огромный лимит в 100,000 символов.
        -- И главное: если лог всё-таки превысит лимит, мы оставляем КОНЕЦ лога,
        -- так как именно там находятся итоги тестов и ошибки компиляции.
        local MAX_LOG_SIZE = 100000
        if #res > MAX_LOG_SIZE then 
            res = "\n...[SYSTEM WARNING: LOG TRUNCATED. SHOWING LAST " .. MAX_LOG_SIZE .. " BYTES]...\n" .. res:sub(-MAX_LOG_SIZE) 
        end

        local output = "\n[SHELL STDOUT/STDERR]:\n" .. res

        -- [CIRCUIT BREAKER]
        ctx.test_failures = ctx.test_failures or 0
        if cmd:match("test") or cmd:match("make") or cmd:match("check") or cmd:match("build") then
            if res:match("[Ee]rror") or res:match("[Ff]ail") or res:match("command not found") or (exit_code and exit_code ~= 0) then
                ctx.test_failures = ctx.test_failures + 1
                if ctx.test_failures >= 3 then
                    output = output .. "\n\n[CIRCUIT BREAKER TRIGGERED]: You have failed this shell validation 3 times in a row. STOP BLIND PATCHING. Read the actual error and use <cmd>read_chunk</cmd> to verify the source code before trying again."
                    ctx.test_failures = 0
                end
            else
                ctx.test_failures = 0
            end
        end

        return { output = output }
    end)

    registry.register("delegate_plan", "Pass execution plan to next stage", function(args, ctx, agent_name)
        local json_match = args:match("(%[.-%])") or args
        local memo_match = args:match("<memo>(.-)</memo>") or ""

        local status, plan = pcall(function() return json:decode(json_match) end)
        if status and type(plan) == "table" and #plan > 0 then
            ctx.execution_plan = plan
            if memo_match ~= "" then ctx.handoff_memo = require("utils").trim(memo_match) end

            local loaded_files = {}
            for _, task in ipairs(plan) do
                if task.file then
                    local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)
                    if not ctx.knowledge_base[rel_path] then
                        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
                        local content = utils.read_file_range(full_path)
                        if content then
                            ctx:add_file(rel_path, content)
                            table.insert(loaded_files, rel_path)
                        end
                    end
                end
            end

            local auto_msg = ""
            if #loaded_files > 0 then
                auto_msg = " Auto-loaded targets into context: " .. table.concat(loaded_files, ", ")
            end

            return { output = "\n[SYSTEM]: Plan delegated successfully." .. auto_msg, signal = "PIPELINE_NEXT_STAGE" }
        end
        return { output = "\n[ERROR]: Invalid JSON plan format. Please provide a valid JSON array.", signal = nil }
    end)

    registry.register("task_complete", "Signal pipeline completion", function(args, ctx, agent_name)
        return { output = "\n[SYSTEM]: Task marked as complete.", signal = "PIPELINE_NEXT_STAGE" }
    end)

    registry.register("ask_user", "Pause execution and ask the human user a question", function(args, ctx, agent_name)
        io.write(string.format("\n\27[33m[AGENT '%s' ASKS]:\27[0m %s\n", agent_name, args))
        io.write("\27[36m>>> YOUR REPLY (or press Enter to skip):\27[0m ")
        local ans = io.read("*l")
        if not ans or utils.trim(ans) == "" then
            return { output = "\n[USER REPLY]: (No response provided by user. Proceed with your best judgment.)" }
        end
        return { output = "\n[USER REPLY]: " .. ans }
    end)

end

return { init = init_core_tools }
