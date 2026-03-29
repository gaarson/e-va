local registry = require("tool_registry")
local core_tools = require("core_tools")
local Context = require("context")
local utils = require("utils")
local patcher = require("patcher")
local os = require("os")

describe("Core Tools via Registry Subsystem", function()
    local ctx
    local test_file = "test_core_file.txt"

    before_each(function()
        registry.tools = {}
        core_tools.init()
        ctx = Context.new({
            PROJECT_ROOT = ".",
            AGENTS = {
                TEST_AGENT = {
                    allowed_tools = { "*" } 
                }
            }
        })
        os.remove(test_file)
    end)

    after_each(function()
        os.remove(test_file)
        os.remove(test_file .. ".bak")
    end)

    it("should deny execution if tool is not allowed", function()
        ctx.config.AGENTS.TEST_AGENT.allowed_tools = { "read_file" }
        local res = registry.execute("patch:dummy\n<<<<<<<\n=======\n>>>>>>>", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("%[SECURITY DENY%]"))
    end)

    it("list_files: should execute and update file_tree", function()
        stub(utils, "list_files_recursive").returns("file1.lua\nfile2.lua")
        local res = registry.execute("list_files", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("updated"))
        assert.are.equal("file1.lua\nfile2.lua", ctx.file_tree)
        utils.list_files_recursive:revert()
    end)

    it("read_file: should handle missing file error", function()
        local res = registry.execute("read_file:nonexistent.lua", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("%[ERROR%]"))
    end)

    it("read_chunk: should read specific lines or return error", function()
        stub(utils, "read_file_numbered").returns("10 | local a = 1", 10)
        local res = registry.execute("read_chunk:test.lua:10-10", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Chunk of 'test.lua'"))

        local res2 = registry.execute("read_chunk:path:test.lua:10-10", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("Chunk"))

        utils.read_file_numbered:revert()
        stub(utils, "read_file_numbered").returns(nil, "error")
        local res_err = registry.execute("read_chunk:test.lua:10-10", ctx, "TEST_AGENT")
        assert.truthy(res_err.output:match("Could not read chunk"))
        utils.read_file_numbered:revert()

        local res_syn = registry.execute("read_chunk:invalid_syntax", ctx, "TEST_AGENT")
        assert.truthy(res_syn.output:match("Usage:"))
    end)

    -- [NEW]: Tests for outline
    it("outline: should execute rg and return AST outline", function()
        utils.write_file(test_file, "dummy content")
        
        -- Mock popen to simulate ripgrep finding a function signature
        local mock_f = { read = function() return "10:local function test_func()" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("outline:" .. test_file, ctx, "TEST_AGENT")
        assert.truthy(res.output:match("SYSTEM OUTLINE FOR"))
        assert.truthy(res.output:match("test_func"))
        io.popen:revert()

        -- Test empty result
        local mock_empty = { read = function() return "" end, close = function() end }
        stub(io, "popen").returns(mock_empty)
        local res_empty = registry.execute("outline:" .. test_file, ctx, "TEST_AGENT")
        assert.truthy(res_empty.output:match("empty or no valid signatures"))
        io.popen:revert()

        -- Test missing file
        local res_missing = registry.execute("outline:missing_file.c", ctx, "TEST_AGENT")
        assert.truthy(res_missing.output:match("%[ERROR%]: File not found"))
    end)

    -- [NEW]: Tests for Context Pinning tools
    it("pin and unpin: should manage context locks", function()
        -- Attempt to pin unread file
        local res_fail = registry.execute("pin:missing.lua", ctx, "TEST_AGENT")
        assert.truthy(res_fail.output:match("not in memory"))

        -- Pin successful
        ctx:add_file("target.lua", "data")
        local res_pin = registry.execute("pin:target.lua", ctx, "TEST_AGENT")
        assert.truthy(res_pin.output:match("Pinned 'target.lua'"))
        assert.is_true(ctx.pinned_files["target.lua"])

        -- Unpin successful
        local res_unpin = registry.execute("unpin:target.lua", ctx, "TEST_AGENT")
        assert.truthy(res_unpin.output:match("Unpinned 'target.lua'"))
        assert.is_nil(ctx.pinned_files["target.lua"])

        -- Attempt to unpin file that is not pinned
        local res_unpin_fail = registry.execute("unpin:target.lua", ctx, "TEST_AGENT")
        assert.truthy(res_unpin_fail.output:match("was not pinned"))
    end)

    it("search: should execute ripgrep search and skip duplicates", function()
        local mock_f = { read = function() return "match1\nmatch2" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("search:query", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("match1"))

        local res2 = registry.execute("search:query", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("Skipped duplicate"))

        local res3 = registry.execute("search:  ", ctx, "TEST_AGENT")
        assert.truthy(res3.output:match("Empty search query"))

        io.popen:revert()
    end)

    it("patch: should handle invalid syntax and disk errors", function()
        local res = registry.execute("patch:invalid_syntax", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Invalid patch syntax"))

        ctx:add_file("target.lua", "1")
        stub(patcher, "apply_patch").returns(false, nil, 0, "fuzzy failed")
        local res3 = registry.execute("patch:target.lua\n<<<<<<< SEARCH\n1\n=======\n2\n>>>>>>> REPLACE", ctx, "TEST_AGENT")
        assert.truthy(res3.output:match("PATCH FAILED"))
        patcher.apply_patch:revert()
    end)

    it("shell: should execute commands, check safety, stream output, and handle circuit breaker", function()
        local res = registry.execute("shell:echo 'shell output'", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("shell output"))

        -- [TEST]: Simple denial (n)
        stub(io, "read").returns("n")
        local res2 = registry.execute("shell:rm -rf /", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("DENIED by user"))
        io.read:revert()

        -- [TEST]: Denial with a custom reason (Closing the feedback loop)
        stub(io, "read").returns("we never delete the root directory, try deleting a specific tmp folder")
        local res_reason = registry.execute("shell:rm -rf /", ctx, "TEST_AGENT")
        assert.truthy(res_reason.output:match("DENIED by user"))
        assert.truthy(res_reason.output:match("Reason: we never delete the root directory, try deleting a specific tmp folder"))
        io.read:revert()

        -- [TEST]: Allowed execution (y)
        stub(io, "read").returns("y")
        local res_allow = registry.execute("shell:rm -rf /fake/path/for/test", ctx, "TEST_AGENT")
        assert.truthy(res_allow.output:match("%[SHELL STDOUT/STDERR%]"))
        io.read:revert()

        -- Circuit breaker for failing tests
        ctx.test_failures = 2
        local res4 = registry.execute("shell:echo 'Error: test failed' && false", ctx, "TEST_AGENT")
        assert.truthy(res4.output:match("CIRCUIT BREAKER TRIGGERED"))
        assert.are.equal(0, ctx.test_failures)
    end)
end)
