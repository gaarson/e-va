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
                    allowed_tools = { "*" } -- Разрешаем все для тестов
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

        -- Fallback syntax test
        local res2 = registry.execute("read_chunk:path:test.lua:10-10", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("Chunk"))

        -- Missing file
        utils.read_file_numbered:revert()
        stub(utils, "read_file_numbered").returns(nil, "error")
        local res_err = registry.execute("read_chunk:test.lua:10-10", ctx, "TEST_AGENT")
        assert.truthy(res_err.output:match("Could not read chunk"))
        utils.read_file_numbered:revert()

        -- Invalid syntax
        local res_syn = registry.execute("read_chunk:invalid_syntax", ctx, "TEST_AGENT")
        assert.truthy(res_syn.output:match("Usage:"))
    end)

    it("search: should execute ripgrep search and skip duplicates", function()
        local mock_f = { read = function() return "match1\nmatch2" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("search:query", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("match1"))

        -- Test duplicate
        local res2 = registry.execute("search:query", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("Skipped duplicate"))

        -- Test empty query
        local res3 = registry.execute("search:  ", ctx, "TEST_AGENT")
        assert.truthy(res3.output:match("Empty search query"))

        io.popen:revert()
    end)

    it("search: should handle empty and huge results", function()
        local mock_f = { read = function() return string.rep("A", 5000) end, close = function() end }
        stub(io, "popen").returns(mock_f)
        local res = registry.execute("search:huge", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Truncated"))
        io.popen:revert()

        local mock_f2 = { read = function() return "" end, close = function() end }
        stub(io, "popen").returns(mock_f2)
        local res2 = registry.execute("search:empty", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("No matches found"))
        io.popen:revert()
    end)

    it("rollback and cleanup_baks: should manage backups", function()
        stub(utils, "restore_backup").returns(true)
        stub(utils, "read_file_range").returns("restored content")
        local res = registry.execute("rollback:test.lua", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Rollback successful"))

        utils.restore_backup:revert()
        stub(utils, "restore_backup").returns(false, "no backup")
        local res2 = registry.execute("rollback:test.lua", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("Rollback failed"))
        utils.restore_backup:revert()
        utils.read_file_range:revert()

        stub(utils, "cleanup_backups").returns(true)
        local res3 = registry.execute("cleanup_baks", ctx, "TEST_AGENT")
        assert.truthy(res3.output:match("All .bak files removed"))
        utils.cleanup_backups:revert()

        stub(utils, "cleanup_backups").returns(false)
        local res4 = registry.execute("cleanup_baks", ctx, "TEST_AGENT")
        assert.truthy(res4.output:match("Failed to clean up"))
        utils.cleanup_backups:revert()
    end)

    it("patch: should handle invalid syntax and disk errors", function()
        local res = registry.execute("patch:invalid_syntax", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Invalid patch syntax"))

        local patch_cmd = "patch:missing.lua\n<<<<<<< SEARCH\n1\n=======\n2\n>>>>>>> REPLACE"
        local res2 = registry.execute(patch_cmd, ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("File not found on disk"))

        ctx:add_file("target.lua", "1")
        stub(patcher, "apply_patch").returns(false, nil, 0, "fuzzy failed")
        local res3 = registry.execute("patch:target.lua\n<<<<<<< SEARCH\n1\n=======\n2\n>>>>>>> REPLACE", ctx, "TEST_AGENT")
        assert.truthy(res3.output:match("PATCH FAILED"))
        patcher.apply_patch:revert()

        stub(patcher, "apply_patch").returns(true, "2", 1)
        stub(utils, "write_file").returns(false, "Permission denied")
        local res4 = registry.execute("patch:target.lua\n<<<<<<< SEARCH\n1\n=======\n2\n>>>>>>> REPLACE", ctx, "TEST_AGENT")
        assert.truthy(res4.output:match("DISK ERROR"))
        patcher.apply_patch:revert()
        utils.write_file:revert()
    end)

    it("create_file: should handle bad syntax and IO errors", function()
        local res = registry.execute("create_file:only_path", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Invalid create_file syntax"))

        stub(utils, "write_file").returns(false, "IO Crash")
        local res2 = registry.execute("create_file:file.txt\ncode", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("IO Crash"))
        utils.write_file:revert()
    end)

    it("shell: should execute commands, check safety, stream output, and handle circuit breaker", function()
        -- Safe command (we use a simple echo that writes to the actual filesystem)
        local res = registry.execute("shell:echo 'shell output'", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("shell output"))

        -- Unsafe command (denied)
        stub(io, "read").returns("n")
        local res2 = registry.execute("shell:rm -rf /", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("DENIED by user"))
        io.read:revert()

        -- Silent command
        -- Silent command (используем echo -n, чтобы пройти safe_prefixes и не дать вывода)
        local res3 = registry.execute("shell:echo -n ''", ctx, "TEST_AGENT")
        assert.truthy(res3.output:match("Command executed silently"))

        -- Circuit breaker for failing tests
-- Circuit breaker for failing tests
        ctx.test_failures = 2
        local res4 = registry.execute("shell:echo 'Error: test failed' && false", ctx, "TEST_AGENT")
        assert.truthy(res4.output:match("CIRCUIT BREAKER TRIGGERED"))
        assert.are.equal(0, ctx.test_failures)
    end)

    it("delegate_plan: should handle invalid JSON", function()
        local res = registry.execute("delegate_plan:bad json", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Invalid JSON"))
    end)
    
    it("ask_user: should successfully capture user input", function()
        stub(io, "read").returns("Yes, proceed")
        local res = registry.execute("ask_user:Is this correct?", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Yes, proceed"))
        io.read:revert()

        -- Fallback if user presses enter (empty input)
        stub(io, "read").returns("")
        local res2 = registry.execute("ask_user:Confirm?", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("No response provided"))
        io.read:revert()
    end)
end)
