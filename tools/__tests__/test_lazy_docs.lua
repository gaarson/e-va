require("luacov")
-- Mock external dependencies
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, error = function() end }
end
package.preload["utils"] = function()
    return {
        trim = function(s)
            if not s then return "" end
            return s:match("^%s*(.-)%s*$") or ""
        end,
    }
end
local registry = require("tool_registry")
-- Helper: reset registry state between tests
local function reset_registry()
    registry.tools = {}
    registry._manifest_cache = {}
    registry._manifest_cache_key = nil
end
-- Mock ctx for execute()
local function make_ctx(agent_name, allowed_tools)
    return {
        config = {
            AGENTS = {
                [agent_name] = {
                    allowed_tools = allowed_tools or {"*"},
                    multi_stage_tools = {},
                    use_selective_multi_stage = false,
                }
            }
        }
    }
end
describe("Lazy Documentation & MCP Progressive Reveal", function()
    before_each(function()
        reset_registry()
    end)
    -- ================================================================
    -- SECTION 1: split_tool_and_args edge cases
    -- ================================================================
    describe("split_tool_and_args", function()
        it("returns (name, '') for bare tool name with no colon", function()
            local name, args = registry.split_tool_and_args("read_file")
            assert.are.equal("read_file", name)
            assert.are.equal("", args)
        end)
        it("returns (name, args) for normal call", function()
            local name, args = registry.split_tool_and_args("read_file:src/main.c")
            assert.are.equal("read_file", name)
            assert.are.equal("src/main.c", args)
        end)
        it("returns (name, '') for tool with colon but empty args", function()
            local name, args = registry.split_tool_and_args("mcp_browser:")
            assert.are.equal("mcp_browser", name)
            assert.are.equal("", args)
        end)
        it("rejects names with spaces", function()
            local name, err = registry.split_tool_and_args("bad name")
            assert.is_nil(name)
            assert.is_not_nil(err)
        end)
    end)
    -- ================================================================
    -- SECTION 2: Lazy doc for regular tools
    -- ================================================================
    describe("Lazy doc: regular tools", function()
        before_each(function()
            registry.register("read_file", "Reads a file into memory",
                "||| COMMAND |||\nread_file:path\n||| END_COMMAND |||",
                function(args, ctx, agent) return { output = "FILE CONTENT: " .. args } end,
                nil, nil, false)
        end)
        it("bare call returns [TOOL_DOCS] not execution result", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("read_file", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[TOOL_DOCS: read_file%]"))
            assert.is_not_nil(res.output:find("%[END_TOOL_DOCS%]"))
            -- Must NOT contain execution result
            assert.is_nil(res.output:find("FILE CONTENT"))
        end)
        it("docs include description and usage", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("read_file", ctx, "test_agent")
            assert.is_not_nil(res.output:find("Reads a file into memory"))
            assert.is_not_nil(res.output:find("read_file:path"))
        end)
        it("normal call with args executes normally (first call includes docs)", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("read_file:src/test.lua", ctx, "test_agent")
            -- First call: docs prepended + result
            assert.is_not_nil(res.output:find("%[TOOL_DOCS: read_file%]"))
            assert.is_not_nil(res.output:find("FILE CONTENT: src/test.lua"))
            -- Second call: clean result only
            local res2 = registry.execute("read_file:src/other.lua", ctx, "test_agent")
            assert.are.equal("FILE CONTENT: src/other.lua", res2.output)
        end)
        it("no_arg_ok tool executes on bare call (no docs)", function()
            reset_registry()
            local executed = false
            registry.register("task_complete", "Signal completion",
                "",
                function(args, ctx, agent)
                    executed = true
                    return { output = "[TASK COMPLETE]" }
                end, nil, nil, true)
            local ctx = make_ctx("test_agent")
            local res = registry.execute("task_complete", ctx, "test_agent")
            assert.is_true(executed)
            assert.are.equal("[TASK COMPLETE]", res.output)
            assert.is_nil(res.output:find("%[TOOL_DOCS"))
        end)
    end)
    -- ================================================================
    -- SECTION 3: MCP parent bare call → command list
    -- ================================================================
    describe("MCP parent: bare call reveals sub-commands", function()
        before_each(function()
            -- Register a fake MCP parent with 3 sub-commands
            local mcp_commands = {
                { name = "navigate", desc = "Open URL in browser" },
                { name = "click",    desc = "Click element by selector" },
                { name = "screenshot", desc = "Take a screenshot" },
            }
            registry.register("mcp_browser", "[MCP Server] browser - call bare to list commands",
                "",
                function(args, ctx, agent)
                    return { output = "[MCP] Should not reach here for bare calls." }
                end, nil, nil, false,
                { is_mcp = true, mcp_commands = mcp_commands })
            -- Register children
            registry.register("mcp_browser_navigate", "Open URL in browser",
                "Usage: mcp_browser_navigate:{\"url\": \"https://...\"}",
                function(args, ctx, agent) return { output = "NAVIGATED" } end,
                nil, nil, false, { mcp_parent = "mcp_browser" })
            registry.register("mcp_browser_click", "Click element by selector",
                "Usage: mcp_browser_click:{\"selector\": \"#btn\"}",
                function(args, ctx, agent) return { output = "CLICKED" } end,
                nil, nil, false, { mcp_parent = "mcp_browser" })
            registry.register("mcp_browser_screenshot", "Take a screenshot",
                "Usage: mcp_browser_screenshot:{\"format\": \"png\"}",
                function(args, ctx, agent) return { output = "SCREENSHOT_TAKEN" } end,
                nil, nil, false, { mcp_parent = "mcp_browser" })
        end)
        it("bare call returns [MCP_COMMANDS] with all sub-commands listed", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("mcp_browser", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[MCP_COMMANDS: mcp_browser%]"))
            assert.is_not_nil(res.output:find("%[END_MCP_COMMANDS%]"))
            assert.is_not_nil(res.output:find("- navigate: Open URL in browser"))
            assert.is_not_nil(res.output:find("- click: Click element by selector"))
            assert.is_not_nil(res.output:find("- screenshot: Take a screenshot"))
            -- Must NOT execute the parent handler
            assert.is_nil(res.output:find("Should not reach here"))
        end)
        it("sub-command name as arg reveals child docs", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("mcp_browser:navigate", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[TOOL_DOCS: mcp_browser_navigate%]"))
            assert.is_not_nil(res.output:find("%[END_TOOL_DOCS%]"))
            assert.is_not_nil(res.output:find("Open URL in browser"))
            -- Must NOT execute the child
            assert.is_nil(res.output:find("NAVIGATED"))
        end)
        it("unknown sub-command falls through to parent handler", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("mcp_browser:nonexistent_cmd", ctx, "test_agent")
            -- Falls through to normal execution → parent handler returns its message
            assert.is_not_nil(res.output:find("%[MCP%]"))
        end)
        it("JSON args on parent fall through to parent handler (not sub-command match)", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute('mcp_browser:{"url":"https://x.com"}', ctx, "test_agent")
            -- Not a bare sub-command name, falls through
            assert.is_not_nil(res.output:find("%[MCP%]"))
        end)
    end)
    -- ================================================================
    -- SECTION 4: MCP child bare call → docs (not execution)
    -- ================================================================
    describe("MCP child: bare call returns docs", function()
        before_each(function()
            registry.register("mcp_browser_navigate", "Open URL in browser",
                "Arguments must be valid JSON:\n{\"url\": \"string\"}\n\nExample:\n||| COMMAND |||\nmcp_browser_navigate:{\"url\": \"https://example.com\"}\n||| END_COMMAND |||",
                function(args, ctx, agent) return { output = "NAVIGATED TO: " .. args } end,
                nil, nil, false, { mcp_parent = "mcp_browser" })
        end)
        it("bare call returns [TOOL_DOCS] with full usage", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("mcp_browser_navigate", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[TOOL_DOCS: mcp_browser_navigate%]"))
            assert.is_not_nil(res.output:find("%[END_TOOL_DOCS%]"))
            assert.is_not_nil(res.output:find("Open URL in browser"))
            assert.is_not_nil(res.output:find("url"))
            -- Must NOT execute
            assert.is_nil(res.output:find("NAVIGATED TO"))
        end)
        it("call with JSON args executes normally (first call includes docs)", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute('mcp_browser_navigate:{"url":"https://x.com"}', ctx, "test_agent")
            -- First call: docs prepended + result
            assert.is_not_nil(res.output:find("%[TOOL_DOCS: mcp_browser_navigate%]"))
            assert.is_not_nil(res.output:find('NAVIGATED TO: {"url":"https://x.com"}'))
        end)
    end)
    -- ================================================================
    -- SECTION 5: Manifest generation — MCP children hidden
    -- ================================================================
    describe("Manifest: MCP children hidden, parents shown", function()
        before_each(function()
            registry.register("read_file", "Reads a file", "usage...", 
                function() return { output = "" } end, nil, nil, false)
            local mcp_commands = {
                { name = "navigate", desc = "Open URL" },
                { name = "click",    desc = "Click element" },
            }
            registry.register("mcp_browser", "[MCP Server] browser", "",
                function() return { output = "" } end, nil, nil, false,
                { is_mcp = true, mcp_commands = mcp_commands })
            registry.register("mcp_browser_navigate", "Open URL", "usage...",
                function() return { output = "" } end, nil, nil, false,
                { mcp_parent = "mcp_browser" })
            registry.register("mcp_browser_click", "Click element", "usage...",
                function() return { output = "" } end, nil, nil, false,
                { mcp_parent = "mcp_browser" })
        end)
        it("manifest shows MCP parent with [MCP] tag", function()
            local manifest = registry.generate_tool_manifest({"*"}, {})
            assert.is_not_nil(manifest:find("`mcp_browser`"))
            assert.is_not_nil(manifest:find("%[MCP%]"))
        end)
        it("manifest does NOT show MCP children individually", function()
            local manifest = registry.generate_tool_manifest({"*"}, {})
            -- Children should be absent as standalone entries
            assert.is_nil(manifest:find("`mcp_browser_navigate`"))
            assert.is_nil(manifest:find("`mcp_browser_click`"))
        end)
        it("manifest shows regular tools normally", function()
            local manifest = registry.generate_tool_manifest({"*"}, {})
            assert.is_not_nil(manifest:find("`read_file`"))
        end)
        it("manifest includes LAZY DOCUMENTATION section", function()
            local manifest = registry.generate_tool_manifest({"*"}, {})
            assert.is_not_nil(manifest:find("LAZY DOCUMENTATION"))
            assert.is_not_nil(manifest:find("NO arguments"))
        end)
        it("manifest includes COMMAND SYNTAX section", function()
            local manifest = registry.generate_tool_manifest({"*"}, {})
            assert.is_not_nil(manifest:find("COMMAND SYNTAX"))
            assert.is_not_nil(manifest:find("||| COMMAND |||"))
        end)
        it("multi-stage tools get [MS] tag in manifest", function()
            reset_registry()
            registry.register("patch", "Apply patch", "usage...",
                function() return { output = "" } end, "MS doc here", nil, false)
            local agent_cfg = { multi_stage_tools = {"patch"} }
            local manifest = registry.generate_tool_manifest({"*"}, agent_cfg)
            assert.is_not_nil(manifest:find("%`patch%` %[MS%]"))
        end)
    end)
    -- ================================================================
    -- SECTION 6: get_detailed_tool_info
    -- ================================================================
    describe("get_detailed_tool_info", function()
        before_each(function()
            registry.register("search", "Fast RipGrep search",
                "||| COMMAND |||\nsearch:pattern\n||| END_COMMAND |||",
                function() return { output = "" } end, nil, nil, false)
        end)
        it("returns formatted doc with name, desc, usage", function()
            local info = registry.get_detailed_tool_info("search", {})
            assert.is_not_nil(info:find("`search`"))
            assert.is_not_nil(info:find("Fast RipGrep search"))
            assert.is_not_nil(info:find("search:pattern"))
        end)
        it("returns nil for unknown tool", function()
            local info = registry.get_detailed_tool_info("nonexistent_tool_xyz", {})
            assert.is_nil(info)
        end)
        it("includes multi-stage doc if tool is MS", function()
            reset_registry()
            registry.register("patch", "Apply patch", "usage...",
                function() return { output = "" } end, "Custom MS behavior text", nil, false)
            local agent_cfg = { multi_stage_tools = {"patch"} }
            local info = registry.get_detailed_tool_info("patch", agent_cfg)
            assert.is_not_nil(info:find("Custom MS behavior text"))
        end)
    end)
    -- ================================================================
    -- SECTION 7: Security / edge cases
    -- ================================================================
    describe("Edge cases & security", function()
        it("unknown tool returns error message", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("nonexistent_tool_xyz", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[ERROR%]: Unknown command"))
        end)
        it("disallowed tool returns security deny", function()
            registry.register("secret_tool", "Secret", "",
                function() return { output = "SECRET" } end, nil, nil, false)
            local ctx = make_ctx("test_agent", {"read_file"})
            local res = registry.execute("secret_tool:arg", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[SECURITY DENY%]"))
        end)
        it("malformed command (empty string) returns error", function()
            local ctx = make_ctx("test_agent")
            local res = registry.execute("", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[ERROR%]"))
        end)
        it("tool handler crash is caught and reported", function()
            registry.register("crashy_tool", "Will crash", "",
                function() error("intentional crash") end, nil, nil, false)
            local ctx = make_ctx("test_agent")
            local res = registry.execute("crashy_tool:arg", ctx, "test_agent")
            assert.is_not_nil(res.output:find("%[FATAL ERROR IN TOOL crashy_tool%]"))
        end)
        it("tool returning non-table is wrapped safely", function()
            registry.register("string_returner", "Returns string", "",
                function() return "just a string" end, nil, nil, false)
            local ctx = make_ctx("test_agent")
            local res = registry.execute("string_returner:arg", ctx, "test_agent")
            -- First call includes docs; result is still present
            assert.is_not_nil(res.output:find("just a string"))
        end)
        it("tool returning table without output field gets empty output", function()
            registry.register("no_output_tool", "No output", "",
                function() return { signal = "done" } end, nil, nil, false)
            local ctx = make_ctx("test_agent")
            local res = registry.execute("no_output_tool:arg", ctx, "test_agent")
            -- First call: docs prepended to empty output; signal preserved
            assert.are.equal("done", res.signal)
            assert.is_not_nil(res.output:find("%[TOOL_DOCS: no_output_tool%]"))
        end)
    end)
    -- ================================================================
    -- SECTION 8: MCP with prefix-based allowed_tools
    -- ================================================================
    describe("MCP prefix-based tool authorization", function()
        before_each(function()
            registry.register("mcp_browser", "[MCP Server] browser", "",
                function() return { output = "" } end, nil, nil, false,
                { is_mcp = true, mcp_commands = { { name = "navigate", desc = "Open URL" } } })
            registry.register("mcp_browser_navigate", "Open URL", "usage...",
                function(args) return { output = "NAV:" .. args } end, nil, nil, false,
                { mcp_parent = "mcp_browser" })
        end)
        it("prefix 'mcp_browser*' allows both parent and children", function()
            local ctx = make_ctx("test_agent", {"mcp_browser*"})
            -- Parent bare call works
            local res1 = registry.execute("mcp_browser", ctx, "test_agent")
            assert.is_not_nil(res1.output:find("%[MCP_COMMANDS"))
            -- Child with args works (first call includes docs)
            local res2 = registry.execute('mcp_browser_navigate:{"url":"x"}', ctx, "test_agent")
            assert.is_not_nil(res2.output:find('NAV:{"url":"x"}'))
        end)
        it("specific tool name allows only that tool", function()
            local ctx = make_ctx("test_agent", {"mcp_browser_navigate"})
            -- Parent is denied
            local res1 = registry.execute("mcp_browser", ctx, "test_agent")
            assert.is_not_nil(res1.output:find("%[SECURITY DENY%]"))
            -- Child is allowed (first call includes docs)
            local res2 = registry.execute('mcp_browser_navigate:{"url":"x"}', ctx, "test_agent")
            assert.is_not_nil(res2.output:find('NAV:{"url":"x"}'))
        end)
    end)
end)
