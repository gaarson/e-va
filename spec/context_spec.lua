local Context = require("context")

describe("Context class", function()
    local mock_config
    local ctx

    before_each(function()
        mock_config = {
            PROJECT_ROOT = "/tmp/test_root",
            LIMITS = { CHARS_PER_TOKEN = 4 }
        }
        ctx = Context.new(mock_config)
    end)

    it("should initialize with empty state", function()
        assert.is_table(ctx.knowledge_base)
        assert.are.equal(0, ctx.global_access_counter)
        assert.is_nil(ctx.identity)
    end)

    it("should correctly add a file and update access counter", function()
        ctx:add_file("main.lua", "print('hello')")

        assert.are.equal("print('hello')", ctx.knowledge_base["main.lua"])
        assert.are.equal("READ", ctx.file_states["main.lua"])
        assert.are.equal(1, ctx.global_access_counter)
        assert.are.equal(1, ctx.file_access_rank["main.lua"])
    end)

    it("should estimate tokens based on config limits", function()
        local cost = ctx:estimate_tokens("123456789012")
        assert.are.equal(3, cost)
    end)

    it("should handle has_searched and search_summary reporting", function()
        assert.is_false(ctx:has_searched("test"))
        ctx:add_search_result("test", "result")
        assert.is_true(ctx:has_searched("test"))
        
        local report = ctx:get_report("CODER")
        assert.truthy(report:match("SEARCH HISTORY"))
    end)

    it("should safely truncate huge file trees in report", function()
        ctx.file_tree = string.rep("A", 100005)
        local report = ctx:get_report("ARCHITECT")
        assert.truthy(report:match("TREE TRUNCATED"))
    end)
    
    it("get_memory_block target OOM branch", function()
        ctx.execution_plan = { { file = "huge.txt" } }
        ctx.current_task_index = 1
        ctx:add_file("huge.txt", string.rep("A", 50000))
        -- Force small budget
        local block = ctx:get_memory_block(10) 
        -- It should still include it partially or fail gracefully without crashing
        assert.truthy(block) 
    end)

    describe("Serialization and State Management", function()
        it("should correctly snapshot and restore full context state", function()
            ctx:add_file("core.c", "int main() {}")
            ctx.identity = { persona = "Kernel Hacker", type = "Daemon" }
            ctx.current_task_index = 2

            local state_json = ctx:snapshot()
            assert.truthy(state_json)

            local new_ctx = Context.new(mock_config)
            local ok, err = new_ctx:load_from_snapshot(state_json)

            assert.is_true(ok)
            assert.is_nil(err)
            assert.are.equal("int main() {}", new_ctx.knowledge_base["core.c"])
            assert.are.equal("Kernel Hacker", new_ctx.identity.persona)
            assert.are.equal(2, new_ctx.current_task_index)
        end)

        it("should securely isolate and serialize agent thoughts", function()
            ctx:add_thought(1, "I need to parse this in English")
            ctx:add_thought(2, "Now applying patch")
            
            local state_json = ctx:snapshot()
            local new_ctx = Context.new(mock_config)
            new_ctx:load_from_snapshot(state_json)

            local found_english = false
            for _, th in pairs(new_ctx.thoughts or {}) do
                if th.content and th.content:match("English") then found_english = true end
            end
            assert.is_true(found_english, "Failed to restore thoughts properly from JSON")
            
            local digest = new_ctx:get_thoughts_digest()
            assert.truthy(digest:match("Turn 1 Thought"))
            assert.truthy(digest:match("Now applying patch"))
        end)

        it("should handle corrupted JSON during snapshot load gracefully", function()
            local ok, err = ctx:load_from_snapshot("{ bad_json: ")
            assert.is_false(ok)
            assert.are.equal("Corrupted JSON", err)
        end)
    end)

    describe("Memory Constraints (get_memory_block)", function()
        it("should omit non-target files when memory is exceeded", function()
            ctx:add_file("small.txt", "hello")
            ctx:add_file("target.txt", "edit me")
            ctx:add_file("huge.txt", string.rep("A", 500))

            ctx.execution_plan = { { file = "target.txt" } }
            ctx.current_task_index = 1

            local mem_block = ctx:get_memory_block(30)

            assert.truthy(mem_block:match("target%.txt %.*%[TARGET FILE %- EDIT THIS%]"))
            assert.truthy(mem_block:match("%[OMITTED %- OUT OF MEMORY%]"))
        end)
    end)

    describe("Search Digest & Context Compression", function()
        it("should deduplicate identical snippets across different files", function()
            ctx:add_search_result("init", "module.lua:10:   local init = false\nmodule.lua:11:   return init")
            ctx:add_search_result("setup", "core.lua:50: local init = false\ncore.lua:51: return init")

            local digest = ctx:get_search_digest(5000)

            local _, match_count = digest:gsub("local init = false", "")
            assert.are.equal(1, match_count, "Duplicate code was not removed!")

            local _, return_count = digest:gsub("return init", "")
            assert.are.equal(1, return_count, "Duplicate return statement was not removed!")
        end)

        it("should aggressively compress whitespaces to save tokens", function()
            local messy_code = "app.c:100:         if ( x == 1 )   {   return true;   }"
            ctx:add_search_result("check_x", messy_code)
            local digest = ctx:get_search_digest(5000)
            assert.truthy(digest:match("if %( x == 1 %) { return true; %}"))
        end)

        it("should truncate digest when token budget is exceeded", function()
            ctx:add_search_result("huge_query", "file.txt:1: " .. string.rep("A", 100))
            local digest = ctx:get_search_digest(10)
            assert.truthy(digest:match("%[TRUNCATED DUE TO TOKEN LIMIT%]"))
        end)
    end)

    describe("Context Squashing (ReAct Optimization)", function()
        it("should successfully squash heavy patch blocks from assistant history", function()
            local raw_msg = "Here is the fix:\n<cmd>patch:file.c\n<<<<<<< SEARCH\nbad_code\n=======\ngood_code\n>>>>>>> REPLACE\n</cmd>"
            
            ctx:add_message("CODER", "user", "Fix it")
            ctx:add_message("CODER", "assistant", raw_msg)

            local squashed = ctx:squash_last_mutation("CODER")

            assert.is_true(squashed)
            local history = ctx:get_history("CODER")
            local final_content = history[#history].content
            
            -- Убеждаемся, что старый код вырезан
            assert.falsy(final_content:match("bad_code"))
            assert.falsy(final_content:match("<<<<<<< SEARCH"))
            -- Убеждаемся, что новое системное сообщение на месте
            assert.truthy(final_content:match("Patch successfully applied to 'file.c'"))
            assert.truthy(final_content:match("Changes are in memory"))
        end)
    end)

    describe("File Synchronization (FS Watcher)", function()
        it("should detect external changes on disk and update knowledge_base", function()
            local utils = require("utils")
            local test_file = "sync_test.txt"
            
            utils.write_file(test_file, "old code")
            ctx.config.PROJECT_ROOT = "."
            ctx:add_file(test_file, "old code")
            
            utils.write_file(test_file, "new fast code")
            
            local synced = ctx:sync_files()
            
            assert.are.equal(1, #synced)
            
            assert.same({test_file}, synced)

            assert.are.equal("new fast code", ctx.knowledge_base[test_file])            
            os.remove(test_file)
        end)
    end)
    
 end)
