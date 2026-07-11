local M = {
    tools = {}
}
local logger = require("logger")
local utils = require("utils")
local inspect = require('inspect')

--- Robust tool_name:args splitter.
--- Finds the FIRST ':' separator. tool_name must be alphanumeric+underscore+dot only.
--- Returns (tool_name, args) or (nil, error_msg).
function M.split_tool_and_args(action_string)
    if not action_string or type(action_string) ~= "string" then
        return nil, "Action string is nil or not a string"
    end
    local idx = action_string:find(":")
    if not idx then
        -- No colon: entire string is the tool name, no args
        local name = utils.trim(action_string)
        if name == "" then
            return nil, "Empty action string"
        end
        -- Validate tool name: alphanumeric, underscore, dot, hyphen only
        if not name:match("^[A-Za-z0-9_%.%-]+$") then
            return nil, string.format("Invalid tool name '%s': contains whitespace or special characters.", name)
        end
        return name, ""
    end
    local tool_name = utils.trim(action_string:sub(1, idx - 1))
    local args = action_string:sub(idx + 1)

    if tool_name == "" then
        return nil, "Empty tool name before ':' separator"
    end
    -- Validate tool name: alphanumeric, underscore, dot, hyphen only
    if not tool_name:match("^[A-Za-z0-9_%.%-]+$") then
        return nil, string.format("Invalid tool name '%s': contains whitespace or special characters.", tool_name)
    end
    return tool_name, args
end

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

    local cmd_name, cmd_args = M.split_tool_and_args(action_string)
    if not cmd_name then
        return { output = "\n[ERROR]: Malformed command syntax: " .. tostring(cmd_args) .. ". Use ||| COMMAND |||\ntool:args\n||| END_COMMAND |||", signal = nil }
    end

    local tool = M.tools[cmd_name]
    if not tool then
        return { output = "\n[ERROR]: Unknown command '" .. cmd_name .. "'.", signal = nil }
    end
    if not is_tool_allowed(agent_cfg, cmd_name) then
        return { output = "\n[SECURITY DENY]: Agent '" .. agent_name .. "' is not authorized to use tool '" .. cmd_name .. "'.", signal = nil }
    end

    -- FIX: pass cmd_args as the first argument, as tool handlers expect (args, ctx, agent_name)
    local status, res = pcall(tool.exec, cmd_args, ctx, agent_name)
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
        "> **PARSING ORDER**: Commands are executed from the **END** of your response. Always place your final/most important command block at the very end of your text.",
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
        for _, pattern in ipairs(allowed_tools) do
            if pattern:sub(-1) == "*" then
                local prefix = pattern:sub(1, -2)
                for tool_name, tool_def in pairs(M.tools) do
                    if tool_name:sub(1, #prefix) == prefix then
                        table.insert(tools_to_list, {name = tool_name, tool = tool_def})
                    end
                end
            else
                if M.tools[pattern] then table.insert(tools_to_list, {name = pattern, tool = M.tools[pattern]}) end
            end
        end
    end

    table.sort(tools_to_list, function(a, b) return a.name < b.name end)

    for _, item in ipairs(tools_to_list) do
        local usage_example = item.tool.usage
        table.insert(doc, string.format("### Tool: `%s`\n**Description**: %s\n**Usage Example**:\n%s\n", item.name, item.tool.desc, usage_example))
    end

    table.insert(doc, "### VISUAL CONTEXT & SCREENSHOTS\nThe system automatically scans the pictures directory at the start of every turn. To show the LLM a screenshot, diagram, or log:\n1. Save the image file to the configured pictures directory (default: .e-va-conf/pictures/).\n2. You can use tools like mcp_browser_take_screenshot (with filePath argument) or shell commands to save images there.\n3. All images in this folder will be automatically attached to the prompt on the **next turn**, allowing the model to visually inspect UI states or errors.")

    -- table.insert(doc, "CRITICAL RULE: You MUST execute `||| COMMAND |||\ntask_complete\n||| END_COMMAND |||` when your instructions are fulfilled to advance the pipeline.")

    return table.concat(doc, "\n")
end

M.is_tool_allowed = is_tool_allowed

return M



