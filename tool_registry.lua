local M = {
    tools = {}
}
local logger = require("logger")
local utils = require("utils")
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
    if not tool_name:match("^[A-Za-z0-9_%.%-]+$") then
        return nil, string.format("Invalid tool name '%s': contains whitespace or special characters.", tool_name)
    end
    return tool_name, args
end
function M.register(name, description, usage, handler, multi_stage_doc, manifest, no_arg_ok, extra)
    if type(handler) ~= "function" then
        logger.error("Failed to register tool: " .. name .. " (handler must be a function)")
        return
    end
    local tool = { desc = description, usage = usage, exec = handler, multi_stage_doc = multi_stage_doc, manifest = manifest, no_arg_ok = (no_arg_ok == true) }
    if extra and type(extra) == "table" then
        for k, v in pairs(extra) do tool[k] = v end
    end
    M.tools[name] = tool
end
--- Get the manifest table for a registered tool.
function M.get_manifest(tool_name)
    local tool = M.tools[tool_name]
    if not tool then return nil end
    return tool.manifest
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
            -- MCP parent: pattern "mcp_browser_*" also allows parent "mcp_browser"
            local base = prefix:sub(1, -2)  -- strip trailing "_"
            if base and tool_name == base and M.tools[tool_name] and M.tools[tool_name].is_mcp then
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
    -- MCP PARENT: bare call → list all sub-commands
    if tool.is_mcp and cmd_args == "" then
        local lines = { "[MCP_COMMANDS: " .. cmd_name .. "]" }
        for _, cmd in ipairs(tool.mcp_commands or {}) do
            table.insert(lines, string.format("- %s: %s", cmd.name, cmd.desc))
        end
        table.insert(lines, "[END_MCP_COMMANDS]")
        return { output = table.concat(lines, "\n"), signal = nil }
    end
    -- MCP PARENT: non-empty args → check if it's a sub-command name (bare, no JSON)
    if tool.is_mcp and cmd_args ~= "" then
        local trimmed_arg = utils.trim(cmd_args)
        for _, cmd in ipairs(tool.mcp_commands or {}) do
            if trimmed_arg == cmd.name then
                local child_name = cmd_name .. "_" .. cmd.name
                local child_tool = M.tools[child_name]
                if child_tool then
                    local doc = M.get_detailed_tool_info(child_name, agent_cfg)
                    return { output = "[TOOL_DOCS: " .. child_name .. "]\n" .. doc .. "\n[END_TOOL_DOCS]", signal = nil }
                end
            end
        end
        -- Not a recognized sub-command name; fall through to normal execution
    end
    -- Lazy doc: empty args on a tool that requires args → return documentation
    if cmd_args == "" and not tool.no_arg_ok then
        local doc = M.get_detailed_tool_info(cmd_name, agent_cfg)
        return { output = "[TOOL_DOCS: " .. cmd_name .. "]\n" .. doc .. "\n[END_TOOL_DOCS]", signal = nil }
    end
    -- FIX: pass cmd_args as the first argument, as tool handlers expect (args, ctx, agent_name)
    local status, res = pcall(tool.exec, cmd_args, ctx, agent_name)
    if not status then
        logger.error("Tool execution FATAL (" .. cmd_name .. ")", res)
        return { output = "\n[FATAL ERROR IN TOOL " .. cmd_name .. "]: " .. tostring(res), signal = nil }
    end
    -- FIX: Ensure tool returns a table with 'output' field to prevent downstream crashes
    if type(res) ~= "table" then
        res = { output = tostring(res) }
    elseif not res.output then
        res.output = ""
    end
    -- First-call docs: prepend tool documentation on the FIRST execution with args
    if cmd_args ~= "" and not tool.no_arg_ok then
        local seen = ctx._tools_first_call_seen
        if not seen then
            seen = {}
            ctx._tools_first_call_seen = seen
        end
        if not seen[cmd_name] then
            seen[cmd_name] = true
            local doc = M.get_detailed_tool_info(cmd_name, agent_cfg)
            if doc then
                res.output = "[TOOL_DOCS: " .. cmd_name .. "]\n" .. doc .. "\n[END_TOOL_DOCS]\n\n" .. res.output
            end
        end
    end
    return res
end
-- Manifest cache: persists across turns to avoid regenerating
M._manifest_cache = {}
M._manifest_cache_key = nil
-- Get detailed tool info for a specific tool (lazy loading)
function M.get_detailed_tool_info(tool_name, agent_cfg)
    agent_cfg = agent_cfg or {}
    local tool = M.tools[tool_name]
    if not tool then return nil end
    local is_ms = false
    if agent_cfg.multi_stage_tools then
        for _, t in ipairs(agent_cfg.multi_stage_tools) do
            if t == tool_name then is_ms = true; break end
        end
    end
    local extra = ""
    if is_ms and tool.multi_stage_doc then
        extra = "\n**MULTI-STAGE BEHAVIOR**: " .. tool.multi_stage_doc
    elseif is_ms then
        extra = "\n**MULTI-STAGE BEHAVIOR**: This tool routes through Intent → Generate → Execute → Review cycle for quality control."
    end
    return string.format("### Tool: `%s`\n**Description**: %s\n**Usage Example**:\n%s%s", tool_name, tool.desc, tool.usage or "", extra)
end
function M.generate_tool_manifest(allowed_tools, agent_cfg)
    agent_cfg = agent_cfg or {}
    local multi_stage_tools = {}
    if agent_cfg.multi_stage_tools then
        for _, t in ipairs(agent_cfg.multi_stage_tools) do
            multi_stage_tools[t] = true
        end
    end
    if not allowed_tools or #allowed_tools == 0 then
        return "\n[SYSTEM WARNING]: You have NO tools assigned. You can only analyze context and chat."
    end
    -- Cache key: based on allowed_tools (mode is always compact now)
    local cache_key = table.concat(allowed_tools, ",") .. "|compact"
    if M._manifest_cache_key == cache_key and M._manifest_cache[cache_key] then
        return M._manifest_cache[cache_key]
    end
    local has_all = false
    for _, allowed in ipairs(allowed_tools) do
        if allowed == "*" then has_all = true end
    end
    local tools_to_list = {}
    if has_all then
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
                -- Also include MCP parent (e.g. "mcp_browser" for pattern "mcp_browser_*")
                local base_name = prefix:sub(1, -2)  -- strip trailing "_"
                if base_name and M.tools[base_name] and M.tools[base_name].is_mcp then
                    table.insert(tools_to_list, {name = base_name, tool = M.tools[base_name]})
                end
            else
                if M.tools[pattern] then table.insert(tools_to_list, {name = pattern, tool = M.tools[pattern]}) end
            end
        end
    end
    table.sort(tools_to_list, function(a, b) return a.name < b.name end)
    local doc = {
        "## TOOLCHAIN INTERFACE",
        "> Commands execute from the **END** of your response. Place final command last.",
        "",
        "### COMMAND SYNTAX (MANDATORY)",
        "ALL tool invocations MUST use EXACTLY this format:",
        "||| COMMAND |||",
        "tool_name:arguments",
        "||| END_COMMAND |||",
        "- Markers on their OWN lines. Pipes (|): use at least 3, any count works.",
        "- NO function-calling JSON. NO plain-text without markers.",
        "",
        "### LAZY DOCUMENTATION",
        "To get full usage docs for ANY tool, issue it with **NO arguments**:",
        "||| COMMAND |||",
        "tool_name",
        "||| END_COMMAND |||",
        "The system will respond with `[TOOL_DOCS: tool_name]` containing complete syntax and examples. Then re-issue the command correctly.",
        "",
        "### ALLOWED TOOLS"
    }
    for _, item in ipairs(tools_to_list) do
        -- SKIP MCP children (hidden behind their parent)
        if item.tool.mcp_parent then
            -- skip
        else
            local is_ms = multi_stage_tools[item.name] == true
            local ms_tag = is_ms and " [MS]" or ""
            local mcp_tag = item.tool.is_mcp and " [MCP]" or ""
            table.insert(doc, string.format("- `%s`%s%s: %s", item.name, ms_tag, mcp_tag, item.tool.desc or ""))
        end
    end
    table.insert(doc, "")
    table.insert(doc, "### SYSTEM ANNOTATIONS")
    table.insert(doc, "- IGNORE `<system-memory>` TAGS in history. Internal bookkeeping only.")
    table.insert(doc, "")
    table.insert(doc, "### VISUAL CONTEXT")
    table.insert(doc, "Images in `.e-va-conf/pictures/` are auto-attached each turn.")
    local result = table.concat(doc, "\n")
    M._manifest_cache[cache_key] = result
    M._manifest_cache_key = cache_key
    return result
end
-- Clear manifest cache (call when tools change)
function M.clear_manifest_cache()
    M._manifest_cache = {}
    M._manifest_cache_key = nil
end
M.is_tool_allowed = is_tool_allowed
return M
