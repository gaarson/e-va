local ui_printer = require('ui.printer')
local ui_colors = require('ui.colors')
local M = {}

--- Prints startup diagnostics in a formatted, readable way.
-- @param config The configuration table
-- @param env_vars Table of environment variables to display {key=value, ...}
function M.print_startup_diagnostics(config, env_vars)
    if not env_vars then env_vars = {} end

    ui_printer.banner('[STARTUP DIAGNOSTICS]', ui_colors.blue)

    local function print_kv(key, value)
        ui_printer.line(string.format('  %s=%s', key, tostring(value or 'UNSET')))
    end

    print_kv('AGENT_HOME', env_vars.AGENT_HOME)
    print_kv('PROJECT_ROOT', env_vars.PROJECT_ROOT)
    print_kv('EVA_STATUS_PORT', env_vars.EVA_STATUS_PORT)
    print_kv('LLM_BASE_URL', env_vars.LLM_BASE_URL)
    print_kv('LLM_MODEL', env_vars.LLM_MODEL)

    -- Masked API key
    local raw_key = env_vars.LLM_API_KEY or env_vars.OPENAI_API_KEY
    local api_key_display = 'UNSET'
    if raw_key and #raw_key > 4 then
        api_key_display = string.sub(raw_key, 1, 4) .. '***'
    end
    print_kv('LLM_API_KEY', api_key_display)

    -- Pipeline summary
    if config.PIPELINE and #config.PIPELINE > 0 then
        local stages = {}
        for _, s in ipairs(config.PIPELINE) do
            table.insert(stages, s.stage)
        end
        print_kv('PIPELINE_STAGES', table.concat(stages, ', '))
    end

    -- Agents summary
    if config.AGENTS then
        local agent_names = {}
        for k in pairs(config.AGENTS) do
            table.insert(agent_names, k)
        end
        print_kv('AGENTS', table.concat(agent_names, ', '))
    end

    -- Pipeline settings
    if config.PIPELINE_SETTINGS then
        print_kv('MAX_TURNS', tostring(config.PIPELINE_SETTINGS.MAX_TURNS or 'UNSET'))
        print_kv('ABORT_ON_FATAL', tostring(config.PIPELINE_SETTINGS.ABORT_ON_FATAL or 'UNSET'))
    end

    ui_printer.banner('[END DIAGNOSTICS]', ui_colors.blue)
end

return M
