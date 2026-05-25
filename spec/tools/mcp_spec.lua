local registry = require("tool_registry")
local Context = require("context")
local inspect = require('inspect')
local json = require("JSON")

local write_calls = {}
local spawn_calls = {}

local mock_ipc = {
    spawn_mcp = function(cmd)
        table.insert(spawn_calls, cmd)
        return { pid = 9999, cmd = cmd }
    end,
    mcp_write = function(proc, payload)
        table.insert(write_calls, payload)
    end,
    mcp_read = function(proc)
        return nil
    end
}
package.loaded["ipc_mcp"] = mock_ipc

local mcp_client = require("tools.mcp_client")
local tools = require("tools")
local config_module = require("config")

describe("Tools: MCP Integration (JSON-RPC & IPC Bridge)", function()
    local ctx
    local original_write = io.write
    local original_config_get = config_module.get

    before_each(function()
        io.write = function() end
        registry.tools = {}

        write_calls = {}
        spawn_calls = {}

        mock_ipc.mcp_read = function(proc) return nil end
        mock_ipc.spawn_mcp = function(cmd)
            table.insert(spawn_calls, cmd)
            return { pid = 9999, cmd = cmd }
        end
        mock_ipc.mcp_write = function(proc, payload)
            table.insert(write_calls, payload)
        end
        mock_ipc.mcp_read = function(proc)
            return nil
        end

        ctx = Context.new({
            PROJECT_ROOT = ".",
            AGENTS = { TEST_AGENT = { allowed_tools = { "*" } } }
        })
    end)

    after_each(function()
        io.write = original_write
        config_module.get = original_config_get
    end)

    describe("MCP Client Protocol Logic", function()
        it("should successfully perform handshake (initialize)", function()
            mock_ipc.mcp_read = function()
                return json:encode({ jsonrpc = "2.0", id = 1, result = { capabilities = {} } })
            end

            local proc = mcp_client.init_server("test_db", "sqlite_mcp")

            assert.is_table(proc)
            assert.are.equal(1, #spawn_calls)
            assert.are.equal("sqlite_mcp", spawn_calls[1])
            assert.are.equal(2, #write_calls) 
        end)

        it("should parse tools/list correctly", function()
            mock_ipc.mcp_read = function()
                return json:encode({
                    jsonrpc = "2.0", id = 2,
                    result = { tools = { { name = "query", description = "Run SQL" } } }
                })
            end

            local tools_list = mcp_client.discover_tools({ pid = 9999 })

            assert.are.equal(1, #tools_list)
            assert.are.equal("query", tools_list[1].name)
        end)

        it("should execute tool and extract text content", function()
            mock_ipc.mcp_read = function()
                return json:encode({
                    jsonrpc = "2.0", id = 3,
                    result = { content = { { type = "text", text = "SELECT result: 42" } } }
                })
            end

            local args_json = '{"sql": "SELECT * FROM t"}'
            local res = mcp_client.execute_tool({ pid = 9999 }, "query", args_json)

            assert.truthy(res.output:match("SELECT result: 42"))

            local last_payload = write_calls[#write_calls]
            assert.truthy(last_payload:match('"sql":"SELECT %* FROM t"'), "Arguments were not passed to payload")
        end)

        it("should catch malformed JSON arguments gracefully", function()
            local res = mcp_client.execute_tool({ pid = 9999 }, "query", '{bad_json: true')
            assert.truthy(res.output:match("Invalid JSON arguments provided"))
            assert.are.equal(0, #write_calls)
        end)
    end)

    describe("Dynamic Registry Injection (tools/init.lua)", function()
        it("should inject MCP tools into E-va tool registry dynamically", function()
            config_module.get = function()
                return { 
                  MCP_SERVERS = { fake_sqlite = "dummy_command" },
                  TEST_AGENT = { allowed_tools = {  } }
                }
            end

            local read_call_count = 3 -- cause of msg_id in mcp_client
            mock_ipc.mcp_read = function(proc)
                read_call_count = read_call_count + 1

                if read_call_count == 4 then
                    return json:encode({ jsonrpc = "2.0", id = 4, result = {} })
                elseif read_call_count == 5 then
                    return json:encode({
                        jsonrpc = "2.0", id = 5,
                        result = { tools = { { name = "read_query", description = "Mock tool" } } }
                    })
                elseif read_call_count == 6 then
                    return json:encode({
                        jsonrpc = "2.0", id = 6,
                        result = { content = { { type = "text", text = "Mock execution success" } } }
                    })
                end

                return nil
            end

            tools.init()

            local expected_tool_name = "mcp_fake_sqlite_read_query"
            assert.is_table(registry.tools[expected_tool_name], "Dynamic tool was not registered!")

            local tool_def = registry.tools[expected_tool_name]
            assert.truthy(tool_def.desc:match("%[fake_sqlite Server%]"))
            assert.truthy(tool_def.usage:match('<cmd>mcp_fake_sqlite_read_query:'))

            local res = registry.execute(expected_tool_name .. ':{ "dummy": 1 }', ctx, "TEST_AGENT")

            print(inspect(res.output))

            assert.truthy(res.output:match("Mock execution success\n"))
        end)
    end)
end)
