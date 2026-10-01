local ui = require('ui')
local M = {}
--- Parse CLI arguments and validate against config.
-- @param cli_args table of command-line arguments (e.g., {...})
-- @param config the loaded configuration table
-- @param logger logger instance
-- @return table {start_file, instruction, is_bootstrap, target_agent, is_pipe}
function M.parse_args(cli_args, config, logger)
    local start_file = nil
    local instruction = nil
    local is_bootstrap = false
    local target_agent = nil
    local is_pipe = false
    local is_debug = false
    local idx = 1
    while idx <= #cli_args do
        local a = cli_args[idx]
        if type(a) == "string" then
            if a == "--bootstrap" then
                is_bootstrap = true
            elseif a == "--pipe" then
                is_pipe = true
            elseif a == "--debug" then
                is_debug = true
            elseif a == "--agent" and idx < #cli_args then
                target_agent = cli_args[idx + 1]
                idx = idx + 1
            elseif not start_file then
                start_file = a
            elseif not instruction then
                instruction = a
            end
        end
        idx = idx + 1
    end

    -- Validate target_agent if specified
    if target_agent then
        if not config.AGENTS or not config.AGENTS[target_agent] then
            ui.print_fatal_block({ Agent = target_agent, Error = "Not found in config.AGENTS" })
            os.exit(1)
        end
        -- Override pipeline for direct execution
        config.PIPELINE = {
            { stage = "DIRECT_EXECUTION", agents = { target_agent }, mode = "sequential" }
        }
        ui.print_success(string.format("Direct execution mode. Overriding pipeline for agent: %s", target_agent))
    end

    return {
        start_file = start_file,
        instruction = instruction,
        is_bootstrap = is_bootstrap,
        target_agent = target_agent,
        is_pipe = is_pipe,
        is_debug = is_debug
    }
end

return M