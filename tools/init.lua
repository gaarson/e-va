local registry = require("tool_registry")
local logger = require("logger")
local function init(provided_config)
    require("tools.update_summary").register(registry)
    require("tools.optimize_context").register(registry)
    require("tools.explore_tree").register(registry)
    require("tools.read_file").register(registry)
    require("tools.read_files").register(registry)
    require("tools.read_chunk").register(registry)
    require("tools.search").register(registry)
    require("tools.patch").register(registry)
    require("tools.create_file").register(registry)
    require("tools.shell").register(registry)
    require("tools.delegate_plan").register(registry)
    require("tools.task_complete").register(registry)
    require("tools.ask_user").register(registry)
    require("tools.outline").register(registry)
    require("tools.pin").register(registry)
    require("tools.unpin").register(registry)
    local config = provided_config
    
    if not config then
        local ok, config_module = pcall(require, "config")
        if ok then
            if type(config_module.get) == "function" then
                local ok2, cfg = pcall(config_module.get)
                if ok2 then config = cfg end
            elseif type(config_module) == "table" then
                config = config_module
            end
        end
    end
    
    if not config then return end
    
    if config.MCP_SERVERS then
        local mcp = require("tools.mcp_client")
        local cjson = require("cjson.safe")
        
        for srv_name, srv_cmd in pairs(config.MCP_SERVERS) do
            local status, proc = pcall(mcp.init_server, srv_name, srv_cmd)
            
            if status and proc then
                logger.info(string.format("[MCP] Connected to '%s'. Requesting tool schema...", srv_name))
                local mcp_tools = mcp.discover_tools(proc)
                
                -- Build mcp_commands list for the parent
                local mcp_commands = {}
                
                for _, tool in ipairs(mcp_tools) do
                    table.insert(mcp_commands, { name = tool.name, desc = tool.description or "" })
                    
                    local eva_tool_name = "mcp_" .. srv_name .. "_" .. tool.name
                    
                    -- Schema for lazy reveal (usage field)
                    local schema_str = cjson.encode(tool.inputSchema or {})
                    if schema_str and #schema_str > 2500 then
                        schema_str = "{\"NOTE\": \"Schema truncated. Use standard intuitive params based on the tool description.\"}"
                    end
                    
                    local usage_doc = string.format(
                        "Arguments must be a valid JSON string conforming to this schema:\n%s\n\nExample:\n||| COMMAND |||\n%s:{\"param\": \"value\"}\n||| END_COMMAND |||",
                        schema_str, eva_tool_name
                    )
                    
                    -- Register child: short desc in manifest (hidden anyway), full doc in usage for lazy reveal
                    registry.register(eva_tool_name,
                        tool.description or "MCP sub-command",
                        usage_doc,
                        function(args_string, ctx, agent_name)
                            local res = mcp.execute_tool(proc, tool.name, args_string)
                            if res and res.output then
                                local max_tokens = (ctx.config.LIMITS and ctx.config.LIMITS.MCP_MAX_OUTPUT_TOKENS) or 4000
                                local token_count = ctx:estimate_tokens(res.output)
                                if token_count > max_tokens then
                                    local chars_per_token = (ctx.config.LIMITS and ctx.config.LIMITS.CHARS_PER_TOKEN) or 3.5
                                    local max_chars = math.floor(max_tokens * chars_per_token)
                                    local truncation_notice = "\n\n[MCP OUTPUT TRUNCATED: exceeded token limit of " .. max_tokens .. " tokens]"
                                    local available_chars = max_chars - #truncation_notice
                                    if available_chars > 0 then
                                        res.output = res.output:sub(1, available_chars) .. truncation_notice
                                    else
                                        res.output = truncation_notice
                                    end
                                end
                            end
                            return res
                        end,
                        nil, nil, false,
                        { mcp_parent = "mcp_" .. srv_name }
                    )
                end
                
                -- Register PARENT tool (the one visible in manifest)
                local parent_name = "mcp_" .. srv_name
                registry.register(parent_name,
                    "[MCP Server] " .. srv_name .. " - call bare to list available commands",
                    "",
                    function(args, ctx, agent_name)
                        -- Should never be reached for bare calls (registry intercepts),
                        -- but if called with a sub-command name as arg, return docs.
                        return { output = "[MCP] Use bare call (no args) to see available commands.", signal = nil }
                    end,
                    nil, nil, false,
                    { is_mcp = true, mcp_commands = mcp_commands }
                )
                
            else
                logger.error(string.format("[MCP FATAL] Failed to initialize server '%s': %s", srv_name, tostring(proc)))
            end
        end
    end
end
return { init = init }
