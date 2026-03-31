local M = {
    tools = {}
}
local logger = require("logger")
local utils = require("utils")

function M.register(name, description, handler)
    if type(handler) ~= "function" then
        logger.error("Failed to register tool: " .. name .. " (handler must be a function)")
        return
    end
    M.tools[name] = { desc = description, exec = handler }
end

local function is_tool_allowed(agent_cfg, tool_name)
    if not agent_cfg or not agent_cfg.allowed_tools then return false end
    for _, allowed in ipairs(agent_cfg.allowed_tools) do
        if allowed == tool_name or allowed == "*" then return true end
    end
    return false
end

function M.execute(action_string, ctx, agent_name)
    local config = ctx.config
    local agent_cfg = config.AGENTS[agent_name]

    local cmd_name, args = action_string:match("^([^:]+):?(.*)")
    if not cmd_name then
        cmd_name = action_string 
        args = ""
    end
    
    cmd_name = utils.trim(cmd_name)
    
    if cmd_name == "" then
        return { output = "\n[ERROR]: Malformed command syntax. Use <cmd>tool:args</cmd>", signal = nil }
    end

    local tool = M.tools[cmd_name]
    if not tool then
        return { output = "\n[ERROR]: Unknown command '" .. cmd_name .. "'.", signal = nil }
    end

    if not is_tool_allowed(agent_cfg, cmd_name) then
        return { output = "\n[SECURITY DENY]: Agent '" .. agent_name .. "' is not authorized to use tool '" .. cmd_name .. "'.", signal = nil }
    end

    local status, res = pcall(tool.exec, args, ctx, agent_name)
    if not status then
        logger.error("Tool execution FATAL (" .. cmd_name .. ")", res)
        return { output = "\n[FATAL ERROR IN TOOL " .. cmd_name .. "]: " .. tostring(res), signal = nil }
    end

    return res
end

return M
