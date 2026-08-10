local colors = require('ui.colors')
local command_parser = require('ui.command_parser')
local input = require('ui.input')
local M = {}
function M.start_hitl_session(target_agent)
    print('\n' .. colors.cyan .. '=== HUMAN-IN-THE-LOOP (HITL) SESSION ===' .. colors.reset)
    print('Type or paste your message freely (supports multiline).')
    print('Press Ctrl+D to submit. Press Ctrl+C to cancel.')
    print('Commands: /go, /back, /mode <stage>, /exit, /status, /help')
end
function M.get_user_input(target_agent)
    local prompt = string.format('\n%s>>> USER -> %s:%s', colors.cyan, target_agent, colors.reset)
    local result = input.read_text(prompt, nil)
    return result
end
function M.print_help()
    print(colors.dim .. 'Available commands:' .. colors.reset)
    print('  /go       - Move to the next pipeline stage')
    print('  /back     - Move back to the previous stage')
    print('  /exit     - Abort execution')
    print('  /mode <s> - Switch to stage <s>')
    print('  /status   - Show current status')
    print('  /help     - Show this help message')
end
function M.parse_command(input, config)
    return command_parser.parse(input, config)
end
return M