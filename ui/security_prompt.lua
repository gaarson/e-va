local utils = require('utils.strings')
local colors = require('ui.colors')
local tty = require('ui.tty')
local M = {}
M._is_tty = tty.is_tty
-- Default behavior when not in TTY mode
-- 'auto_approve' = always return true
-- 'auto_deny' = always return false
-- 'prompt' = force prompt anyway (may hang if no stdin)
M.non_tty_mode = 'auto_deny'
function M.set_non_tty_mode(mode)
    if mode == 'auto_approve' or mode == 'auto_deny' or mode == 'prompt' then
        M.non_tty_mode = mode
    end
end
--- Generic confirmation wrapper
-- @param prompt string: The question to ask
-- @param default string: 'y' or 'n'
-- @return boolean allowed, string|nil reason
function M.confirm(prompt, default)
    default = default or 'n'
    if not M._is_tty then
        if M.non_tty_mode == 'auto_approve' then return true, nil
        elseif M.non_tty_mode == 'auto_deny' then return false, 'User declined'
        else
            if default == 'y' then return true, nil
            else return false, 'Default: declined' end
        end
    end
    local input = require('ui.input')
    local result = input.confirm(prompt, default)
    if result then return true, nil
    else return false, 'User declined' end
end
--- Confirm execution of a shell command
-- Replaces inline logic in tools/shell.lua
-- @param agent_name string
-- @param cmd string
-- @return boolean allowed, string|nil reason
function M.confirm_execution(agent_name, cmd)
    if not M._is_tty then
        if M.non_tty_mode == 'auto_approve' then return true, nil
        elseif M.non_tty_mode == 'auto_deny' then return false, 'User declined'
        else return false, 'Non-TTY prompt mode: auto-denied' end
    end
    io.write(string.format("\n%s[SECURITY WARNING]%s Agent '%s' wants to execute: %s%s%s%s\n",
        colors.red, colors.reset,
        agent_name,
        colors.yellow, cmd, colors.reset,
        colors.reset))
    local input = require('ui.input')
    local result = input.confirm_with_reason(
        string.format("Agent '%s' wants to execute: %s", agent_name, cmd), 'n')
    return result.allowed, result.reason
end
--- Confirm session restoration
-- Replaces inline logic in agent/state.lua
-- @return boolean: true if user wants to restore, false otherwise
function M.confirm_session_restore()
    if not M._is_tty then
        if M.non_tty_mode == 'auto_approve' then return true, nil
        elseif M.non_tty_mode == 'auto_deny' then return false, 'User declined'
        end
    end
    local input = require('ui.input')
    return input.confirm('\n[SYSTEM] Previous session found. Continue (y) or start new (n)?', 'n')
end
return M