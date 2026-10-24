local M = {}

--- Loads custom tools from .e-va-conf/custom_tools.lua
--- @param config table: Configuration table containing PROJECT_ROOT
--- @param registry table: Tool registry to register tools against
--- @param utils table: Utils module
--- @param Context table: ContextFlow class/module
--- @param logger table: Logger module

function M.load_custom_tools(config, registry, utils, Context, logger)
    local custom_tools_path = config.PROJECT_ROOT .. "/.e-va-conf/custom_tools.lua"

    local custom_tools_func = loadfile(custom_tools_path)
    if custom_tools_func then

        local ok, err = pcall(function()
            local setup_tools = custom_tools_func()
            if type(setup_tools) == "function" then
                setup_tools(registry, utils, Context)
            end
        end)

        if not ok then
            logger.error("Failed to load custom tools: " .. tostring(err))
        end
    end
end

return M
