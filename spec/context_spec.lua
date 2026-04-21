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
        assert.is_table(ctx.pinned_files)
    end)

    it("should correctly add a file and update access counter", function()
        ctx:add_file("main.lua", "print('hello')")

        assert.are.equal("print('hello')", ctx.knowledge_base["main.lua"])
        assert.are.equal("READ", ctx.file_states["main.lua"])
        assert.are.equal(1, ctx.global_access_counter)
        assert.are.equal(1, ctx.file_access_rank["main.lua"])
    end)

    it("should securely manage pinned files", function()
        ctx:add_file("core.lua", "local a = 1")
        
        assert.is_true(ctx:pin_file("core.lua"))
        assert.is_true(ctx.pinned_files["core.lua"])
        
        assert.is_false(ctx:pin_file("missing.lua"))
        
        assert.is_true(ctx:unpin_file("core.lua"))
        assert.is_nil(ctx.pinned_files["core.lua"])
        
        assert.is_false(ctx:unpin_file("missing.lua"))
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

    describe("Serialization and State Management", function()
        it("should correctly snapshot and restore full context state including pins", function()
            ctx:add_file("core.c", "int main() {}")
            ctx:pin_file("core.c")
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
            assert.is_true(new_ctx.pinned_files["core.c"])
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

    describe("Memory Constraints and Positional Inversion", function()
        it("should omit non-target files when memory is exceeded, but keep target", function()
            ctx:add_file("small.txt", "hello")
            ctx:add_file("target.txt", "edit me")
            ctx:add_file("huge.txt", string.rep("A", 500))

            ctx.execution_plan = { { file = "target.txt", instruction = "fix" } }
            ctx.current_task_index = 1

            local mem_block = ctx:get_memory_block(30)

            assert.truthy(mem_block:match("<file_target path=\"target%.txt\" instruction=\"fix\">"))
            assert.truthy(mem_block:match("status=\"OMITTED_OUT_OF_MEMORY\""))
        end)

        it("should prioritize high-rank (MRU) files during memory pressure", function()
            ctx:add_file("low.txt", "Content Low")
            ctx:add_file("mid.txt", "Content Mid")
            ctx:add_file("high.txt", "Content High")

            ctx:touch_file("low.txt")
            ctx:touch_file("mid.txt")
            ctx:touch_file("high.txt")

            local mem_block = ctx:get_memory_block(60)

            assert.truthy(mem_block:match("high%.txt"), "High-rank file should be preserved")
            assert.truthy(mem_block:match("low%.txt") and mem_block:match("OMITTED_OUT_OF_MEMORY"), "Low-rank file should be evicted")
        end)

        it("should prioritize RECENTLY_MODIFIED files and assign them a specific XML status", function()
            ctx:add_file("bg.txt", "background context")
            ctx:add_file("edited.txt", "newly edited code")
            ctx:add_file("target.txt", "active target")
            
            ctx.file_states["edited.txt"] = "RECENTLY_MODIFIED"
            ctx.execution_plan = { { file = "target.txt", instruction = "update" } }
            ctx.current_task_index = 1

            local mem_block = ctx:get_memory_block(10000)

            local pos_modified = mem_block:find('<file_context path="edited.txt" status="RECENTLY_MODIFIED">', 1, true)
            local pos_bg = mem_block:find('<file_context path="bg.txt"', 1, true)
            local pos_target = mem_block:find('<file_target path="target.txt"', 1, true)

            assert.is_not_nil(pos_modified, "Missing RECENTLY_MODIFIED XML block")
            
            assert.is_true(pos_modified < pos_bg, "Recently modified files must appear BEFORE read-only background context")
            assert.is_true(pos_bg < pos_target, "General context must appear BEFORE the primary target workspace")
        end)

        it("should prioritize MRU files during memory pressure eviction", function()
            ctx:add_file("file1.txt", "Some content for file 1")
            ctx:add_file("file2.txt", "Some content for file 2")
            ctx:add_file("file3.txt", "Some content for file 3")

            -- Set rank: file1 (1), file2 (2), file3 (3)
            ctx:touch_file("file1.txt")
            ctx:touch_file("file2.txt")
            ctx:touch_file("file3.txt")

            -- Force file2 to be the most recent (MRU)
            ctx:touch_file("file2.txt")

            -- Total tokens for 3 files is approx 3 * (~25 tokens) = 75.
            -- We set limit to 40 to force eviction of everything except the highest rank.
            local mem_block = ctx:get_memory_block(40)

            assert.truthy(mem_block:match("file2%.txt"), "MRU file (file2) must be included")
            assert.truthy(mem_block:match("OMITTED_OUT_OF_MEMORY"), "Non-MRU files must be marked as OMITTED")
            assert.truthy(mem_block:match("file1%.txt.*OMITTED_OUT_OF_MEMORY"), "Lower rank file (file1) must be marked as OMITTED")
        end)

        it("should enforce Positional Inversion and XML Boundary Framing", function()
            ctx:add_file("bg.txt", "background context")
            ctx:add_file("target.txt", "active target")
            ctx:add_file("pinned.txt", "critical constants")
            
            ctx:pin_file("pinned.txt")
            ctx.execution_plan = { { file = "target.txt", instruction = "update" } }
            ctx.current_task_index = 1

            local mem_block = ctx:get_memory_block(10000)

            local pos_pinned = mem_block:find('<file_context path="pinned.txt"', 1, true)
            local pos_bg = mem_block:find('<file_context path="bg.txt"', 1, true)
            local pos_target = mem_block:find('<file_target path="target.txt"', 1, true)

            assert.is_not_nil(pos_pinned, "Missing Pinned XML block. Dump:\n" .. mem_block)
            assert.is_not_nil(pos_bg, "Missing General Context XML block. Dump:\n" .. mem_block)
            assert.is_not_nil(pos_target, "Missing Target XML block. Dump:\n" .. mem_block)

            assert.is_true(pos_pinned < pos_target, "Pinned context must appear BEFORE target")
            assert.is_true(pos_bg < pos_target, "General context must appear BEFORE target")
        end)

        it("should inject an accurate execution plan checklist into the memory block", function()
            ctx.execution_plan = {
                { file = "module_a.lua", instruction = "init" },
                { file = "module_b.lua", instruction = "process" },
                { file = "module_c.lua", instruction = "cleanup" }
            }
            ctx.current_task_index = 2 
            
            ctx:add_file("module_b.lua", "-- dummy content")

            local mem_block = ctx:get_memory_block(10000)

            assert.truthy(mem_block:match("=== EXECUTION PLAN STATUS ==="), "Checklist header must be present")
            assert.truthy(mem_block:match("%[x%] Step 1: module_a%.lua"), "Step 1 must be marked as completed")
            assert.truthy(mem_block:match("%[>%] Step 2: module_b%.lua"), "Step 2 must be marked as active")
            assert.truthy(mem_block:match("%[ %] Step 3: module_c%.lua"), "Step 3 must be marked as pending")
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

    describe("Context Squashing (Safe Memory Markers)", function()
        it("should replace heavy patch blocks with safe SYSTEM MEMORY markers", function()
            local raw_msg = "Here is my CoT reasoning:\n<cmd>patch:file.c\n<<<<<<< SEARCH\nbad_code\n=======\ngood_code\n>>>>>>> REPLACE\n</cmd>\nSome trailing thoughts."

            ctx:add_message("CODER", "user", "Fix the bug")
            ctx:add_message("CODER", "assistant", raw_msg)

            local squashed = ctx:squash_last_mutation("CODER")

            assert.is_true(squashed)
            local history = ctx:get_history("CODER")
            local final_content = history[#history].content

            assert.falsy(final_content:match("<<<<<<< SEARCH"), "Patch markers must be removed")
            assert.falsy(final_content:match("bad_code"), "Code snippet must be removed")
            assert.falsy(final_content:match("<cmd>patch:"), "Command tag must be removed to prevent syntax hallucination")

            assert.truthy(final_content:match("%[SYSTEM MEMORY: You successfully executed a patch on 'file%.c'"), "Safe memory marker must be injected")

            assert.truthy(final_content:match("Here is my CoT reasoning:"), "Preceding text must be preserved")
            assert.truthy(final_content:match("Some trailing thoughts."), "Trailing text must be preserved")
        end)

        it("should inject safe markers for create_file blocks as well", function()
            local raw_msg = "<think>creating</think>\n<cmd>create_file:new.js\nconst a = 1;\n</cmd>"
            
            ctx:add_message("CODER", "assistant", raw_msg)
            local squashed = ctx:squash_last_mutation("CODER")
            
            assert.is_true(squashed)
            local final_content = ctx:get_history("CODER")[#ctx:get_history("CODER")].content
            
            assert.truthy(final_content:match("%[SYSTEM MEMORY: You successfully created/overwrote file 'new%.js'"), "Safe marker for create_file must be injected")
            assert.truthy(final_content:match("<think>creating</think>"), "Thoughts must be preserved")
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

    describe("Thought Deduplication (Jaccard Similarity Engine)", function()
        it("should merge exact substring continuations", function()
            ctx:add_thought(1, "I need to read the file.")
            ctx:add_thought(2, "I need to read the file. Now I will patch it.")

            assert.are.equal(1, #ctx.thoughts)
            assert.are.equal(2, ctx.thoughts[1].merged)
            assert.truthy(ctx.thoughts[1].content:match("Now I will patch it"))
        end)

        it("should merge highly similar rephrased thoughts", function()
            ctx:add_thought(1, "The schema is broken, I must fix the database tables.")
            ctx:add_thought(2, "I must fix the database tables because the schema is broken.")

            assert.are.equal(1, #ctx.thoughts)
            assert.are.equal(2, ctx.thoughts[1].merged)
        end)

        it("should not merge completely different thoughts", function()
            ctx:add_thought(1, "I am analyzing the network stack.")
            ctx:add_thought(2, "I am generating the UI components for the frontend.")

            assert.are.equal(2, #ctx.thoughts)
        end)

        it("should format the digest with merge counters", function()
            ctx:add_thought(1, "Setup complete.")
            ctx:add_thought(2, "Setup complete.")
            ctx:add_thought(3, "Setup complete.")

            local digest = ctx:get_thoughts_digest()
            assert.truthy(digest:match("Merged x3"))
        end)
    end)
end)
