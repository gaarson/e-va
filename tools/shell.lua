local utils = require("utils")
local os = require("os")
local ui = require("ui")
local shell_session = require("tools.shell_session")
local SHELL_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        if not payload or utils.trim(payload) == "" then
            return false, "shell payload is empty."
        end
        return true, nil
    end,
    estimate_complexity = function()
        return "complex"
    end,
    enrich_result = function(output_str)
        return output_str
    end,
    intent_guideline = "shell: Executes POSIX shell commands. For interactive programs use  to start a session, then session=<id> input=<text> to send input.",
}
local MAX_LOG_SIZE = 1000000
local function truncate_output(res)
    if #res > MAX_LOG_SIZE then
        return "\n...[SYSTEM WARNING: LOG TRUNCATED. SHOWING LAST " .. MAX_LOG_SIZE .. " BYTES]...\n" .. res:sub(-MAX_LOG_SIZE)
    end
    return res
end
local function register(registry)
    registry.register("shell",
        "Executes POSIX shell commands with 60s timeout. Supports non-interactive (default), interactive sessions (for sudo/ssh/etc). Circuit breaker: 3 consecutive test/build failures triggers STOP warning.",
        "||| COMMAND |||\nshell:make test\n||| END_COMMAND |||\n\nMODES:\n1. Non-interactive (default): shell:<command>\n   - 60s hard timeout (configurable via LIMITS.SHELL_TIMEOUT). Output truncated at 1MB.\n   - Polling interval: 100ms, max wait: 90s.\n   - Circuit breaker: if command matches test|make|check|build AND fails 3x consecutively -> STOP warning injected.\n\n2. Interactive session:\n   Start: shell:<command> \n   Send input: shell:session=<id> input=<text>\n   Poll output: shell:session=<id>\n   Close: shell:session=<id> close=true\n   - Max lifetime: 300s, max interactions: 50.\n\nSAFETY:\n- Blocked: sudo, rm -rf /, redirect to /etc/ or /usr/bin/, curl|sh, wget|sh.\n- Warned: chmod 777, writes to /etc/ via flags.\n- User confirmation prompt shown before execution (configurable in ui.security_prompt).",
        function(args, ctx, agent_name)
            args = args or ""
            -- === SESSION MODE: session=<id> ===
            local session_id = args:match("^%s*session%s*=%s*(%S+)")
            if session_id then
                local is_close = args:match("close%s*=%s*true") ~= nil
                local input = args:match("input%s*=%s*(.+)")
                if is_close then
                    local ok = shell_session.close(session_id)
                    if ok then
                        return { output = "\n[SHELL SESSION]: Session " .. session_id .. " closed." }
                    else
                        return { output = "\n[SHELL SESSION ERROR]: Unknown session " .. session_id }
                    end
                end
                if input then
                    local result, err = shell_session.send_input(session_id, utils.trim(input))
                    if not result then
                        return { output = "\n[SHELL SESSION ERROR]: " .. tostring(err) }
                    end
                    local out = "\n[SHELL SESSION " .. session_id .. "]:\n" .. result.output
                    if not result.alive then
                        out = out .. "\n\n[SESSION COMPLETE] Exit code: " .. tostring(result.exit_code or 0)
                        shell_session.close(session_id)
                    else
                        out = out .. "\n\n[SESSION ACTIVE] Send more input with: shell:session=" .. session_id .. " input=<text>"
                    end
                    return { output = out }
                end
                -- Just poll
                local result, err = shell_session.poll(session_id)
                if not result then
                    return { output = "\n[SHELL SESSION ERROR]: " .. tostring(err) }
                end
                local out = "\n[SHELL SESSION " .. session_id .. "]:\n" .. (result.output ~= "" and result.output or "(no new output)")
                if not result.alive then
                    out = out .. "\n\n[SESSION COMPLETE] Exit code: " .. tostring(result.exit_code or 0)
                    shell_session.close(session_id)
                else
                    out = out .. "\n\n[SESSION ACTIVE] Send input with: shell:session=" .. session_id .. " input=<text>"
                end
                return { output = out }
            end
            -- === INTERACTIVE START:  ===
            local interactive = args:match("interactive%s*=%s*true") ~= nil
            if interactive then
                args = args:gsub("interactive%s*=%s*true", "")
            end
            local cmd = utils.trim(args)
            if cmd == "" then
                return { output = "[SHELL]: No command provided." }
            end
            local allowed, reason = ui.security_prompt.confirm_execution(agent_name, cmd)
            if not allowed then
                if reason == "denied" then
                    return { output = "\n[SYSTEM]: Command execution DENIED by user." }
                end
                return { output = string.format("\n[SYSTEM]: Command execution DENIED. Reason: %s", reason) }
            end
            if interactive then
                -- Start interactive session
                ui.printer.line(string.format("\n[SYSTEM: Starting interactive session: '%s']", cmd))
                local session, err = shell_session.start(cmd)
                if not session then
                    return { output = "\n[SHELL SESSION ERROR]: " .. tostring(err) }
                end
                local out = "\n[SHELL SESSION " .. session.id .. " STARTED]:\n"
                if session.output ~= "" then
                    out = out .. session.output
                else
                    out = out .. "(waiting for program output...)"
                end
                if not session.alive then
                    out = out .. "\n\n[SESSION COMPLETE] Exit code: " .. tostring(session.exit_code or 0)
                    shell_session.close(session.id)
                else
                    out = out .. "\n\n[SESSION ACTIVE] To send input: shell:session=" .. session.id .. " input=<your text>"
                    out = out .. "\nTo poll for output: shell:session=" .. session.id
                    out = out .. "\nTo close: shell:session=" .. session.id .. " close=true"
                end
                return { output = out }
            end
            -- === NON-INTERACTIVE MODE (original) ===
            ui.printer.line(string.format("\n[SYSTEM: Executing '%s']", cmd))
            local tmp_file = os.tmpname()
            local exit_file = tmp_file .. ".exit_code"
            local tmp_script = os.tmpname() .. ".sh"
            local sf = io.open(tmp_script, "w")
            if sf then sf:write("#!/bin/sh\n" .. cmd); sf:close() end
            local shell_timeout = (ctx.config and ctx.config.LIMITS and ctx.config.LIMITS.SHELL_TIMEOUT) or 60
            local wrapper_script = string.format(
                "timeout %d sh '%s' > '%s' 2>&1; echo $? > '%s'",
                shell_timeout, tmp_script, tmp_file, exit_file
            )
            os.execute(wrapper_script .. " &")
            local output_chunks = {}
            local last_pos = 0
            local exit_code = nil
            local POLL_TIMEOUT = 90
            local poll_start = os.time()
            while true do
                local f = io.open(tmp_file, "rb")
                if f then
                    f:seek("set", last_pos)
                    local chunk = f:read("*a")
                    if chunk and #chunk > 0 then
                        ui.printer.raw(chunk)
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
                if os.time() - poll_start > POLL_TIMEOUT then
                    ui.printer.line("\n[SYSTEM WARNING: Polling timeout exceeded.]")
                    break
                end
                os.execute("sleep 0.1")
            end
            ui.printer.line("\n[SYSTEM: Execution finished]")
            os.remove(tmp_file)
            os.remove(exit_file)
            os.remove(tmp_script)
            local res = table.concat(output_chunks)
            if #res == 0 then
                res = "(Command executed silently. Status: " .. tostring(exit_code or 0) .. ")"
            end
            res = truncate_output(res)
            local output = "\n[SHELL STDOUT/STDERR]:\n" .. res
            ctx.test_failures = ctx.test_failures or 0
            if cmd:match("test") or cmd:match("make") or cmd:match("check") or cmd:match("build") then
                if res:match("[Ee]rror") or res:match("[Ff]ail") or res:match("command not found") or (exit_code and exit_code ~= 0) then
                    ctx.test_failures = ctx.test_failures + 1
                    if ctx.test_failures >= 3 then
                        output = output .. "\n\n[CIRCUIT BREAKER TRIGGERED]: You have failed this shell validation 3 times in a row. STOP BLIND PATCHING. Read the actual error and use read_chunk to verify the source code before trying again."
                        ctx.test_failures = 0
                    end
                else
                    ctx.test_failures = 0
                end
            end
            return { output = output }
        end,
        nil, SHELL_MANIFEST)
end
return { register = register }