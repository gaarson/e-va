local multi_stage = require("multi_stage_executor")
local utils = require("utils")
require("tools").init(nil)
-- Helper: create a mock context with knowledge_base
local function make_mock_ctx(kb)
    local ctx = {
        config = {
            PROJECT_ROOT = "/tmp/test_project",
            AGENTS = {
                test_agent = {
                    allowed_tools = {"patch", "create_file", "shell", "read_file", "delegate_plan"}
                }
            },
            CREATE_BACKUPS = false
        },
        knowledge_base = kb or {},
        file_states = {},
        squash_last_mutation = function(self, name) end,
        add_file = function(self, path, content)
            self.knowledge_base[path] = content
        end
    }
    return ctx
end
describe("multi_stage_executor - Context Injection in Generate Prompt", function()
    it("build_generate_prompt includes knowledge_base content when file is referenced in intent", function()
        local source_code = "class SessionRegistry:\n    def get_or_create(self, user_id):\n        pass\n"
        local ctx = make_mock_ctx({
            ["agents/chat/api.py"] = source_code
        })
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Extract SessionRegistry from agents/chat/api.py into session_registry.py",
            "Project file tree",
            "create_file",
            "Move SessionRegistry class",
            "File contains SessionRegistry with get_or_create method",
            "agents/chat/session_registry.py"
        )
        local prompt = executor:build_generate_prompt()
        assert.truthy(prompt:find("agents/chat/api.py", 1, true), "prompt should reference the source file path")
        assert.truthy(prompt:find("SessionRegistry", 1, true), "prompt should contain source code content")
        assert.truthy(prompt:find("<project_context>", 1, true), "prompt should have project_context wrapper")
    end)
    it("build_generate_prompt does NOT include unrelated files from knowledge_base", function()
        local ctx = make_mock_ctx({
            ["unrelated/module.py"] = "def foo():\n    return 42\n",
            ["agents/chat/api.py"] = "class SessionRegistry:\n    pass\n"
        })
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Extract from agents/chat/api.py",
            "Project file tree",
            "create_file",
            "Move class",
            "File has the class",
            "agents/chat/session_registry.py"
        )
        local prompt = executor:build_generate_prompt()
        assert.truthy(prompt:find("agents/chat/api.py", 1, true), "should include referenced file")
        assert.falsy(prompt:find("unrelated/module.py", 1, true), "should NOT include unrelated file")
        assert.falsy(prompt:find("return 42", 1, true), "should NOT contain unrelated file content")
    end)
    it("build_generate_prompt context_block is capped at max length", function()
        -- Create a very large file (exceeds 8000 char cap)
        local large_content = string.rep("local x = 1\n", 5000) -- ~60000 chars
        local ctx = make_mock_ctx({
            ["huge/file.lua"] = large_content
        })
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Process huge/file.lua",
            "Context",
            "create_file",
            "Copy content",
            "File matches source",
            "huge/copy.lua"
        )
        local prompt = executor:build_generate_prompt()
        -- The context block should be present but truncated (not full 60000 chars)
        assert.truthy(prompt:find("<project_context>", 1, true), "should have context wrapper")
        -- Total prompt should not be absurdly large (cap is ~8000 chars for context)
        local context_section = prompt:match("<project_context>(.-)</project_context>")
        if context_section then
            assert.is_true(#context_section < 12000, "context block should be capped (got " .. #context_section .. " chars)")
        end
    end)
    it("start_task_with_intent stores project_context on executor", function()
        local ctx = make_mock_ctx({})
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Do something",
            "My custom project context string",
            "create_file",
            "Hint",
            "Criteria",
            "test.lua"
        )
        assert.equals(executor.project_context, "My custom project context string", "project_context should be stored")
    end)
    it("build_generate_prompt works correctly when knowledge_base is empty", function()
        local ctx = make_mock_ctx({})
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Create a new file",
            "Context",
            "create_file",
            "New module",
            "Module loads correctly",
            "src/new_mod.lua"
        )
        local prompt = executor:build_generate_prompt()
        assert.truthy(prompt, "prompt should not be nil")
        assert.falsy(prompt:find("<project_context>", 1, true), "should NOT have project_context when KB is empty")
        -- Should still have the basic generate prompt structure
        assert.truthy(prompt:find("Command Generator", 1, true), "should have base prompt text")
    end)
    it("build_generate_prompt includes target FILE_PATH content if it exists in knowledge_base", function()
        local existing_content = "local M = {}\nfunction M.hello()\nend\nreturn M\n"
        local ctx = make_mock_ctx({
            ["src/target.lua"] = existing_content
        })
        local executor = multi_stage.new(ctx, "test_agent")
        executor:start_task_with_intent(
            "Modify src/target.lua",
            "Context",
            "create_file",
            "Update module",
            "Module has new function",
            "src/target.lua"
        )
        local prompt = executor:build_generate_prompt()
        assert.truthy(prompt:find("src/target.lua", 1, true), "should reference target file")
        assert.truthy(prompt:find("function M.hello()", 1, true), "should contain existing file content as reference")
    end)
end)
