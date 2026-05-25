local M = {}
-- ИСПОЛЬЗУЕМ CJSON ДЛЯ БЕЗОПАСНОСТИ ПАМЯТИ
local json = require("cjson.safe")
local ipc = require("ipc_mcp") 
local utils = require("utils")
local logger = require("logger")

local msg_id = 0

local function rpc_call(proc, method, params)
    msg_id = msg_id + 1
    local req = {
        jsonrpc = "2.0",
        id = msg_id,
        method = method,
        params = params or {}
    }

    ipc.mcp_write(proc, json.encode(req))

    while true do
        logger.info(string.format("[LUA-DEBUG] Waiting for IPC read on method '%s'...", method))
        local raw_res = ipc.mcp_read(proc)
        logger.info(string.format("[LUA-DEBUG] IPC read returned type: %s", type(raw_res)), raw_res)

        if not raw_res then return nil, "Pipe closed or server crashed" end

        logger.info(string.format("[LUA-DEBUG] Processing string of length: %d bytes", #raw_res))

        local first_char = ""
        local snippet_limit = math.min(100, #raw_res)
        for i = 1, snippet_limit do
            local c = raw_res:sub(i, i)
            if c ~= " " and c ~= "\n" and c ~= "\r" and c ~= "\t" then
                first_char = c
                break
            end
        end

        logger.info("[LUA-DEBUG] First valid char identified as: '" .. tostring(first_char) .. "'")

        if first_char == "{" then
            logger.info("[LUA-DEBUG] Attempting cjson.decode...")
            local res, err = json.decode(raw_res)
            logger.info("[LUA-DEBUG] cjson.decode finished. Success: " .. tostring(res ~= nil))

            if res and type(res) == "table" then
                if res.id == msg_id then
                    return res, nil
                elseif res.method then
                    logger.info("[MCP Async Event]: " .. tostring(res.method))
                end
            else
                logger.warn("[MCP JSON PARSE ERROR]: " .. tostring(err) .. " (Length: " .. #raw_res .. ")")
            end
        elseif first_char ~= "" then
            local snippet = raw_res:sub(1, 100):gsub("\n", " ")
            logger.warn("[MCP STDOUT POLLUTION]: " .. snippet)
        end
    end
end

function M.init_server(name, command)
    logger.info("Initializing MCP Server: " .. name)
    local proc = ipc.spawn_mcp(command)
    if not proc then error("Failed to spawn MCP server") end

    local init_res, err = rpc_call(proc, "initialize", {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "e-va-agent", version = "1.0.0" }
    })

    if not init_res then error("Failed handshake: " .. tostring(err)) end

    local notif = { jsonrpc = "2.0", method = "notifications/initialized" }
    ipc.mcp_write(proc, json.encode(notif))

    return proc
end

function M.discover_tools(proc)
    local res, err = rpc_call(proc, "tools/list", {})
    if not res or not res.result or not res.result.tools then
        logger.error("Failed to load schema: " .. tostring(err))
        return {}
    end
    return res.result.tools
end

function M.execute_tool(proc, tool_name, json_args_string)
    local args_table = {}
    if json_args_string and utils.trim(json_args_string) ~= "" then
        local decoded, err = json.decode(json_args_string)
        if decoded and type(decoded) == "table" then 
            args_table = decoded 
        else
            return { output = "[MCP ERROR] Invalid JSON arguments provided.", signal = nil }
        end
    end

    local res, err = rpc_call(proc, "tools/call", {
        name = tool_name,
        arguments = args_table
    })

    if not res then return { output = "[MCP IPC ERROR]: " .. tostring(err), signal = nil } end
    if res.error then return { output = "[MCP EXECUTION ERROR]: " .. json.encode(res.error), signal = nil } end

    local output = ""
    for _, content_block in ipairs(res.result.content or {}) do
        if content_block.type == "text" then output = output .. content_block.text .. "\n" end
    end

    return { output = output, signal = nil }
end

return M
