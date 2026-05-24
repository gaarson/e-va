local M = {
    tools = {}
}
local logger = require("logger")
local utils = require("utils")

function M.register(name, description, usage, handler)
    if type(handler) ~= "function" then
        logger.error("Failed to register tool: " .. name .. " (handler must be a function)")
        return
    end
    M.tools[name] = { desc = description, usage = usage, exec = handler }
end

local function is_tool_allowed(agent_cfg, tool_name)
    if not agent_cfg or not agent_cfg.allowed_tools then return false end
    
    for _, allowed in ipairs(agent_cfg.allowed_tools) do
        if allowed == tool_name or allowed == "*" then return true end
        
        if allowed:sub(-1) == "*" then
            local prefix = allowed:sub(1, -2)
            if tool_name:sub(1, #prefix) == prefix then 
                return true 
            end
        end
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

function M.generate_tool_manifest(allowed_tools)
    if not allowed_tools or #allowed_tools == 0 then
        return "\n[SYSTEM WARNING]: You have NO tools assigned. You can only analyze context and chat."
    end

    local doc = {
        "## SYSTEM DIRECTIVE: TOOLCHAIN INTERFACE",
        "You must interact with the environment using strict XML tags.",
        "CRITICAL: Do NOT invent tools. Only the following tools are available to your profile:\n"
    }

    local has_all = false
    for _, allowed in ipairs(allowed_tools) do
        if allowed == "*" then has_all = true end
    end

    local tools_to_list = {}
    if has_all then
        table.insert(doc, "**(Admin privileges granted: ALL_TOOLS enabled)**\n")
        for name, tool in pairs(M.tools) do table.insert(tools_to_list, {name = name, tool = tool}) end
    else
        for _, name in ipairs(allowed_tools) do
            if M.tools[name] then table.insert(tools_to_list, {name = name, tool = M.tools[name]}) end
        end
    end

    table.sort(tools_to_list, function(a, b) return a.name < b.name end)

    for _, item in ipairs(tools_to_list) do
        table.insert(doc, string.format("### Tool: `<cmd>%s</cmd>`\n**Description**: %s\n**Usage Example**:\n```xml\n%s\n```\n", item.name, item.tool.desc, item.tool.usage))
    end

    -- table.insert(doc, "CRITICAL RULE: You MUST execute `<cmd>task_complete</cmd>` when your instructions are fulfilled to advance the pipeline.")

    return table.concat(doc, "\n")
end

return M
