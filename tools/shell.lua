local utils = require("utils")
local os = require("os")

local function register(registry)
    registry.register("shell", "Executes POSIX shell commands with streaming output and timeouts (Mandatory for linters/tests)", "<cmd>shell:make test</cmd>", function(args, ctx, agent_name)
        local cmd = utils.trim(args)
        local safe_prefixes = { "ls", "cat", "grep", "rg", "echo", "pwd", "ps", "find", "head", "tail", "whoami", "make", "test", "npm", "cargo" }
        local is_safe = false

        for _, prefix in ipairs(safe_prefixes) do
            if cmd:match("^" .. prefix .. "%s") or cmd == prefix then is_safe = true; break end
        end

        if not is_safe then
            io.write(string.format("\n\27[31m[SECURITY WARNING]\27[0m Agent '%s' wants to execute: \27[33m%s\27[0m\n", agent_name, cmd))
            io.write("Allow execution? (y = yes, n = no, or type a reason to deny): ")
            local raw_ans = io.read("*l")
            local ans = utils.trim(raw_ans or "n")

            if ans:lower() == "y" or ans:lower() == "yes" then
            elseif ans == "" or ans:lower() == "n" or ans:lower() == "no" then
                return { output = "\n[SYSTEM]: Command execution DENIED by user. Do not try this command again." }
            else
                return { output = string.format("\n[SYSTEM]: Command execution DENIED by user. Reason: %s", ans) }
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

        local MAX_LOG_SIZE = 1000000
        if #res > MAX_LOG_SIZE then
            res = "\n...[SYSTEM WARNING: LOG TRUNCATED. SHOWING LAST " .. MAX_LOG_SIZE .. " BYTES]...\n" .. res:sub(-MAX_LOG_SIZE)
        end

        local output = "\n[SHELL STDOUT/STDERR]:\n" .. res

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
end

return { register = register }