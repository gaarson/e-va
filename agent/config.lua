local M = {}

function M.load_config(agent_home, project_root, utils)
    local config = assert(utils.load_config(agent_home .. "/config.lua"), "CRITICAL: Could not load base config.lua")
    local local_config = utils.load_config(project_root .. "/.e-va-conf/config.lua")

    if local_config then
        config = utils.deep_merge(config, local_config)
        print("\n\27[36m[SYSTEM INFO]: Applied local overrides from .e-va-conf/config.lua\27[0m")
        config = utils.apply_agent_defaults(config)
    end

    if type(config.PIPELINE) ~= "table" or #config.PIPELINE == 0 then
        print("\n\27[33m[SYSTEM WARNING]: Bypassing config file. Injecting memory-safe PIPELINE.\27[0m")
        config.PIPELINE = {
            { stage = "ANALYSIS_AND_PLANNING", agents = { "ARCHITECT" }, mode = "sequential" },
            { stage = "REVIEW_AND_CHAT", agents = { "ARCHITECT" }, mode = "interactive" },
            { stage = "IMPLEMENTATION", agents = { "CODER" }, mode = "sequential" }
        }
    end
    config = utils.apply_agent_defaults(config)

    return config
end

return M