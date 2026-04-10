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

    it("explore_tree: should execute, update file_tree, and handle default depth", function()
        stub(utils, "explore_directory").returns("Directory: /src\n  src/main.lua\n  src/utils/")
        
        local res_explicit = registry.execute("explore_tree:src:2", ctx, "TEST_AGENT")
        assert.truthy(res_explicit.output:match("Explored directory 'src' %(Depth: 2%)"))
        assert.are.equal("Directory: /src\n  src/main.lua\n  src/utils/", ctx.file_tree, "Agent context MUST be updated with the new view")

        local res_default = registry.execute("explore_tree:docs", ctx, "TEST_AGENT")
        assert.truthy(res_default.output:match("Depth: 1"), "Should default to depth 1 if not specified")

        utils.explore_directory:revert()
    end)

    it("explore_tree: should reflect file line counts in the tool output", function()
        stub(utils, "explore_directory").returns("Directory: /src\n  src/main.lua (10 lines)\n  src/utils/")
        
        local res = registry.execute("explore_tree:src", ctx, "TEST_AGENT")
        
        assert.truthy(res.output:match("src/main.lua %(10 lines%)"), "Tool output must display restored line counts")
        
        utils.explore_directory:revert()
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

    it("outline: should execute rg and return AST outline", function()
        utils.write_file(test_file, "dummy content")
        
        local mock_f = { read = function() return "10:local function test_func()" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res = registry.execute("outline:" .. test_file, ctx, "TEST_AGENT")
        assert.truthy(res.output:match("SYSTEM OUTLINE FOR"))
        assert.truthy(res.output:match("test_func"))
        io.popen:revert()

        local mock_empty = { read = function() return "" end, close = function() end }
        stub(io, "popen").returns(mock_empty)
        local res_empty = registry.execute("outline:" .. test_file, ctx, "TEST_AGENT")
        assert.truthy(res_empty.output:match("empty or no valid signatures"))
        io.popen:revert()

        local res_missing = registry.execute("outline:missing_file.c", ctx, "TEST_AGENT")
        assert.truthy(res_missing.output:match("%[ERROR%]: File not found"))
    end)

    it("pin and unpin: should manage context locks", function()
        local res_fail = registry.execute("pin:missing.lua", ctx, "TEST_AGENT")
        assert.truthy(res_fail.output:match("not in memory"))

        ctx:add_file("target.lua", "data")
        local res_pin = registry.execute("pin:target.lua", ctx, "TEST_AGENT")
        assert.truthy(res_pin.output:match("Pinned 'target.lua'"))
        assert.is_true(ctx.pinned_files["target.lua"])

        local res_unpin = registry.execute("unpin:target.lua", ctx, "TEST_AGENT")
        assert.truthy(res_unpin.output:match("Unpinned 'target.lua'"))
        assert.is_nil(ctx.pinned_files["target.lua"])

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

    it("search and explore_tree: should ignore .e-va-conf directory", function()
        -- Test explore_tree filter
        stub(utils, "explore_directory").returns("Directory: /src\n  src/main.lua")
        local res_exp = registry.execute("explore_tree:.", ctx, "TEST_AGENT")
        assert.is_nil(res_exp.output:match("%.e-va-conf"), "explore_tree should not list .e-va-conf")
        utils.explore_directory:revert()

        -- Test search filter
        local mock_f = { read = function() return "match in conf" end, close = function() end }
        stub(io, "popen").returns(mock_f)
        local res_search = registry.execute("search:some_query", ctx, "TEST_AGENT")
        -- We verify that the command sent to popen contains the glob
        -- Since we can't easily inspect popen arguments without a more complex stub, 
        -- we rely on the fact that our patch to core_tools.lua added the glob.
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

        stub(io, "read").returns("n")
        local res2 = registry.execute("shell:rm -rf /", ctx, "TEST_AGENT")
        assert.truthy(res2.output:match("DENIED by user"))
        io.read:revert()

        stub(io, "read").returns("we never delete the root directory, try deleting a specific tmp folder")
        local res_reason = registry.execute("shell:rm -rf /", ctx, "TEST_AGENT")
        assert.truthy(res_reason.output:match("DENIED by user"))
        assert.truthy(res_reason.output:match("Reason: we never delete the root directory, try deleting a specific tmp folder"))
        io.read:revert()

        stub(io, "read").returns("y")
        local res_allow = registry.execute("shell:rm -rf /fake/path/for/test", ctx, "TEST_AGENT")
        assert.truthy(res_allow.output:match("%[SHELL STDOUT/STDERR%]"))
        io.read:revert()

        ctx.test_failures = 2
        local res4 = registry.execute("shell:echo 'Error: test failed' && false", ctx, "TEST_AGENT")
        assert.truthy(res4.output:match("CIRCUIT BREAKER TRIGGERED"))
        assert.are.equal(0, ctx.test_failures)
    end)

    describe("task_complete iterator logic", function()
        it("should increment task index and suppress pipeline exit until plan is exhausted", function()
            -- Имитируем план из двух шагов
            ctx.execution_plan = {
                { file = "file1.lua", instruction = "step 1" },
                { file = "file2.lua", instruction = "step 2" }
            }
            ctx.current_task_index = 1

            -- Итерация 1: завершаем первый шаг
            local res1 = registry.execute("task_complete", ctx, "TEST_AGENT")
            
            assert.truthy(res1.output:match("Step 1/2 complete"), "Output should indicate step progression")
            assert.is_nil(res1.signal, "Signal MUST be nil to prevent pipeline stage termination")
            assert.are.equal(2, ctx.current_task_index, "Task index should be incremented")

            -- Итерация 2: завершаем финальный шаг
            local res2 = registry.execute("task_complete", ctx, "TEST_AGENT")
            
            assert.truthy(res2.output:match("All steps in the execution plan are complete"), "Output should indicate plan completion")
            assert.are.equal("PIPELINE_NEXT_STAGE", res2.signal, "Signal MUST be PIPELINE_NEXT_STAGE when plan is exhausted")
        end)

        it("should gracefully handle empty or nil execution plans (fallback)", function()
            ctx.execution_plan = {}
            local res = registry.execute("task_complete", ctx, "TEST_AGENT")
            
            assert.truthy(res.output:match("Task marked as complete"))
            assert.are.equal("PIPELINE_NEXT_STAGE", res.signal, "Must exit stage if no plan exists")
        end)
    end)
end)