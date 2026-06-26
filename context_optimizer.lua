local logger = require('logger')

local M = {}

function M.is_context_exceeded(err_body)
    if not err_body or type(err_body) ~= 'string' then
        return false
    end
    local lower_body = string.lower(err_body)
    local patterns = {
        'maximum context length',
        'context length',
        'input_tokens',
        'total of at least',
        'reduce the length'
    }
    for _, pattern in ipairs(patterns) do
        if string.find(lower_body, pattern) then
            return true
        end
    end
    return false
end

function M.shrink_max_tokens(agent_cfg, min_threshold)
    min_threshold = min_threshold or 1024
    if not agent_cfg or not agent_cfg.params then
        return min_threshold
    end
    local current = agent_cfg.params.max_tokens
    if not current or current <= min_threshold then
        return current or min_threshold
    end
    local new_val = math.floor(current / 2)
    if new_val < min_threshold then
        new_val = min_threshold
    end
    agent_cfg.params.max_tokens = new_val
    logger.info(string.format('Context optimizer: reduced max_tokens from %d to %d', current, new_val))
    return new_val
end

return M