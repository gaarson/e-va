local M = {}
local function apply_env_overrides(config)
    local os = require("os")
    local applied = false
    -- Resolve API key: LLM_API_KEY > OPENAI_API_KEY
    local api_key = os.getenv("LLM_API_KEY")
    if not api_key or api_key == "" then
        api_key = os.getenv("OPENAI_API_KEY")
    end
    -- Resolve base URL
    local base_url = os.getenv("LLM_BASE_URL")
    -- Resolve model
    local model = os.getenv("LLM_MODEL")
    -- Helper to apply to a single agent table
    local function apply_to_agent(agent)
        if type(agent) ~= "table" then return end
        if api_key and api_key ~= "" then
            agent.token = api_key
            applied = true
        end
        if base_url and base_url ~= "" then
            agent.url = base_url
            applied = true
        end
        if model and model ~= "" then
            agent.model = model
            applied = true
        end
    end
    -- Apply to AGENT_DEFAULTS
    if config.AGENT_DEFAULTS then
        apply_to_agent(config.AGENT_DEFAULTS)
    end
    -- Apply to OPTIMIZER_AGENT
    if config.OPTIMIZER_AGENT then
        apply_to_agent(config.OPTIMIZER_AGENT)
    end
    -- Apply to each agent in AGENTS
    if config.AGENTS then
        for _, agent in pairs(config.AGENTS) do
            apply_to_agent(agent)
        end
    end
    if applied then
        print("\n\27[36m[SYSTEM INFO]: Environment variable overrides applied (highest priority)\27[0m")
    end
end
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
    -- Environment variable overrides (highest priority)
    apply_env_overrides(config)
    return config
end
return M