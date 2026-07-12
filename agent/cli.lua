local M = {}

--- Parse CLI arguments and validate against config.
-- @param cli_args table of command-line arguments (e.g., {...})
-- @param config the loaded configuration table
-- @param logger logger instance
-- @return table {start_file, instruction, is_bootstrap, target_agent}
function M.parse_args(cli_args, config, logger)
    local start_file = nil
    local instruction = nil
    local is_bootstrap = false
    local target_agent = nil
    local idx = 1

    while idx <= #cli_args do
        local a = cli_args[idx]
        if type(a) == "string" then
            if a == "--bootstrap" then
                is_bootstrap = true
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
            print(string.format("\n\27[31m[FATAL] Agent '%s' not found in config.AGENTS\27[0m", target_agent))
            os.exit(1)
        end
        -- Override pipeline for direct execution
        config.PIPELINE = {
            { stage = "DIRECT_EXECUTION", agents = { target_agent }, mode = "sequential" }
        }
        print(string.format("\n\27[36m[SYSTEM INFO]: Direct execution mode. Overriding pipeline for agent: %s\27[0m", target_agent))
    end

    return {
        start_file = start_file,
        instruction = instruction,
        is_bootstrap = is_bootstrap,
        target_agent = target_agent
    }
end

return M