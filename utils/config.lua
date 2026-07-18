
local M = {}


function M.deep_merge(base, specific)

    local res = {}

    if type(base) == "table" then

        for k, v in pairs(base) do res[k] = type(v) == "table" and M.deep_merge({}, v) or v end

    end

    if type(specific) == "table" then

        for k, v in pairs(specific) do res[k] = type(v) == "table" and M.deep_merge(res[k] or {}, v) or v end

    end

    return res

end


function M.load_config(filepath)

    local chunk, err = loadfile(filepath)

    if not chunk then return nil, err end

    local ok, res = pcall(chunk)

    if not ok then return nil, "Execution error: " .. tostring(res) end

    if type(res) == "table" then

        if type(res.get) == "function" then

            return res.get()

        end

        return res

    end

    return nil, "Config must return a table"

end


function M.apply_agent_defaults(config)

    if not config or not config.AGENTS then return config end

    local defaults = config.AGENT_DEFAULTS

    if not defaults then return config end

    local function apply_one(agent)

        if type(agent) ~= "table" then return end

        if agent.url == nil and defaults.url ~= nil then agent.url = defaults.url end

        if agent.model == nil and defaults.model ~= nil then agent.model = defaults.model end

        if agent.is_reasoning == nil and defaults.is_reasoning ~= nil then agent.is_reasoning = defaults.is_reasoning end

        if agent.prompt_file == nil and defaults.prompt_file ~= nil then agent.prompt_file = defaults.prompt_file end

        if agent.allowed_tools == nil and defaults.allowed_tools ~= nil then agent.allowed_tools = defaults.allowed_tools end

        if defaults.params then

            agent.params = M.deep_merge(defaults.params, agent.params or {})

        end

    end

    for _, agent in pairs(config.AGENTS) do

        apply_one(agent)

    end

    return config

end


return M

