local registry = require("tool_registry")
local logger = require("logger")

local function init(provided_config)
    require("tools.explore_tree").register(registry)
    require("tools.read_file").register(registry)
    require("tools.read_chunk").register(registry)
    require("tools.search").register(registry)
    require("tools.rollback").register(registry)
    require("tools.cleanup_baks").register(registry)
    require("tools.patch").register(registry)
    require("tools.create_file").register(registry)
    require("tools.shell").register(registry)
    require("tools.delegate_plan").register(registry)
    require("tools.task_complete").register(registry)
    require("tools.ask_user").register(registry)
    require("tools.outline").register(registry)
    require("tools.pin").register(registry)
    require("tools.unpin").register(registry)
    require("tools.trace_execution").register(registry)

    local config = provided_config
    
    if not config then
        local ok, config_module = pcall(require, "config")
        if ok then
            if type(config_module.get) == "function" then
                config = config_module.get()
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
                
                for _, tool in ipairs(mcp_tools) do
                    local eva_tool_name = "mcp_" .. srv_name .. "_" .. tool.name
                    print("[DEBUG MCP TOOL DISCOVERY] -> " .. eva_tool_name)
                    local usage_example = string.format("<cmd>%s:{\"param\": \"value\"}</cmd>", eva_tool_name)
                    
                    local schema_str = cjson.encode(tool.inputSchema or {})
                    
                    -- ЗАЩИТА: Отсекаем гигантские схемы от браузерных MCP
                    if schema_str and #schema_str > 2500 then
                        schema_str = "{\"NOTE\": \"Schema truncated to protect token limit. Use standard intuitive params based on the tool description.\"}"
                    end
                    
                    local description = string.format(
                        "[%s Server] %s\nIMPORTANT: Arguments must be a valid JSON string conforming to this schema: %s", 
                        srv_name, 
                        tool.description or "No description", 
                        schema_str
                    )
                    
                    registry.register(eva_tool_name, description, usage_example, function(args_string, ctx, agent_name)
                        return mcp.execute_tool(proc, tool.name, args_string)
                    end)
                end
            else
                logger.error(string.format("[MCP FATAL] Failed to initialize server '%s': %s", srv_name, tostring(proc)))
            end
        end
    end
end

return { init = init }