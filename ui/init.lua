local M = {}
local tty = require('ui.tty')
M.is_tty = tty.is_tty
-- Output Mode: 'full', 'minimal', 'silent'
M.mode = 'full'
function M.configure(mode)
    if mode == 'full' or mode == 'minimal' or mode == 'silent' then
        M.mode = mode
    end
end
-- Submodules
M.colors = require('ui.colors')
M.printer = require('ui.printer')
M.input = require('ui.input')
M.status = require('ui.status')
M.interrupt = require('ui.interrupt')
M.pipeline_ui = require('ui.pipeline_ui')
M.stream = require('ui.stream')
M.security_prompt = require('ui.security_prompt')
M.crash_report = require('ui.crash_report')
M.diagnostics = require('ui.diagnostics')
M.progress = require('ui.progress')
M.command_parser = require('ui.command_parser')
-- Re-export stream functions at top level for backward compatibility
M.stream_token_printer = M.stream.stream_token_printer
M.flush_stream_buffer = M.stream.flush_stream_buffer

-- Convenience wrappers (mode-aware)
local function should_output()
  return M.mode ~= 'silent'
end
function M.print_turn_header(turn, agent_name, tokens, max_tokens)
  if not should_output() then return end
  M.printer.banner(string.format('[Turn %d | Agent: %s | Tokens: ~%d/%d]', turn, agent_name, tokens, max_tokens), M.colors.dim)
end
function M.print_ai_prompt(agent_name, stage)
  if not should_output() then return end
  local suffix = stage and ' [' .. stage .. ']' or ''
  io.write(string.format('\n%s>>> AI (%s)%s:%s ', M.colors.magenta, agent_name, suffix, M.colors.reset))
end
function M.print_user_prompt(agent_name)
  if not should_output() then return end
  io.write(string.format('\n%s>>> USER -> %s:%s ', M.colors.cyan, agent_name, M.colors.reset))
end
function M.ask_question(agent_name, question)
  if not should_output() then return end
  M.printer.highlight(string.format('[AGENT "%s" ASKS]: %s', agent_name, question), M.colors.yellow)
  return M.input.read_line('>>> YOUR REPLY (or press Enter to skip):', M.colors.cyan)
end
function M.print_stage_header(idx, total, stage_name)
  if not should_output() then return end
  M.printer.divider()
  M.printer.banner(string.format('[STAGE %d/%d] %s', idx, total, stage_name))
  M.printer.divider()
end
function M.print_error(msg)
  if not should_output() then return end
  M.printer.highlight('[ERROR] ' .. msg, M.colors.red)
end
function M.print_warning(msg)
  if not should_output() then return end
  M.printer.highlight('[WARNING] ' .. msg, M.colors.yellow)
end
function M.print_success(msg)
  if not should_output() then return end
  M.printer.highlight('[OK] ' .. msg, M.colors.green)
end
function M.print_fatal_block(fields)
  if not should_output() then return end
  M.printer.fatal_block(fields)
end
--- Prints a welcome banner for the interactive session.
-- @param agent_name string: Name of the active agent
function M.print_welcome(agent_name)
  if not should_output() then return end
  M.printer.divider('=')
  M.printer.banner('  E-va Interactive Session')
  M.printer.divider('=')
  M.printer.line(string.format('  Active Agent: %s', agent_name or 'N/A'))
  M.printer.line('')
  M.printer.line('  Slash Commands:')
  M.printer.line('    /go       - Advance to next pipeline stage')
  M.printer.line('    /back     - Return to previous stage')
  M.printer.line('    /mode <s> - Jump to named stage')
  M.printer.line('    /status   - Show current pipeline status')
  M.printer.line('    /help     - Show this help again')
  M.printer.line('    /exit     - Abort execution')
  M.printer.line('')
  M.printer.line('  Use Up/Down arrows to navigate input history.')
  M.printer.divider('=')
end
return M