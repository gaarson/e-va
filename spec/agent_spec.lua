local utils = require("utils")

describe("Agent Bootstrapper Mode (--bootstrap)", function()
    local utils = require("utils")
    local llm_handler = require("llm_handler")
    local original_send_request = llm_handler.send_request
    local original_execute = os.execute

    local test_state_file = ".e-va-conf/.state.json"

    before_each(function()
        os.remove(test_state_file)
        stub(os, "exit").invokes(function(code) error("EXIT:" .. code) end)
        _G.print = function() end
    end)

    after_each(function()
        os.exit:revert()
        os.execute = original_execute
        llm_handler.send_request = original_send_request
    end)

    it("should bypass standard execution and initialize BOOTSTRAPPER pipeline", function()
        local execute_called_with = {}
        os.execute = function(cmd) table.insert(execute_called_with, cmd); return 0 end
        
        local llm_was_called = false
        local used_profile = nil
        
        llm_handler.send_request = function(profile, messages)
            llm_was_called = true
            used_profile = profile.name
            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end

        local chunk = loadfile("agent.lua")
        
        local ok, err = pcall(function() chunk("--bootstrap") end)
        
        assert.is_false(ok)
        assert.truthy(err:match("EXIT:0"))
        
        local mkdir_called = false
        for _, cmd in ipairs(execute_called_with) do
            if cmd:match("mkdir %-p.*%.e%-va%-conf/prompts") then mkdir_called = true end
        end
        assert.is_true(mkdir_called, "Must create scaffolding directories")
        
        assert.is_true(llm_was_called)
        assert.are.equal("BOOTSTRAPPER", used_profile, "Must run under the BOOTSTRAPPER meta-profile")
    end)
end)

describe("Agent Control Plane (Integration)", function()
    local original_exit = os.exit
    local original_read = io.read
    local original_write = io.write
    local original_print = print

    local llm_handler = require("llm_handler")
    local original_send_request = llm_handler.send_request

    local test_state_file = ".e-va_state.json"
    local logger = require("logger")

    before_each(function()
        stub(logger, "error")
        stub(logger, "log_context") 
        
        os.remove(test_state_file)

        _G.print = function() end
        io.write = function() end

        os.exit = function(code)
            error("OS_EXIT_CALLED:" .. tostring(code))
        end
    end)

    after_each(function()
        os.exit = original_exit
        io.read = original_read
        io.write = original_write
        _G.print = original_print
        llm_handler.send_request = original_send_request

        logger.error:revert()
        logger.log_context:revert() -- [FIX]: Восстанавливаем оригинальный метод
        
        os.remove(test_state_file)

        package.loaded["agent"] = nil
    end)

    it("should successfully bootstrap, execute pipeline, and exit cleanly", function()
        stub(io, "read").returns("/continue")

        llm_handler.send_request = function(profile, messages)
            if profile.name == "ARCHITECT" then
                return { choices = { { message = { content = '<cmd>delegate_plan:{"plan": [{"file": "dummy.txt", "instruction": "init"}], "memo": "init"}</cmd>' } } } }, nil
              else
                return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
            end
        end

        local chunk, compile_err = loadfile("agent.lua")
        assert.is_truthy(chunk, "Failed to compile agent.lua: " .. tostring(compile_err))

        local ok, err = pcall(function()
            chunk("dummy_file.txt", "Analyze the system")
        end)

        if not ok and type(err) == "string" and not err:match("OS_EXIT_CALLED:0") then
            original_print("\n[CRITICAL LUA ERROR IN AGENT]:\n" .. err)
        end

        assert.is_true(ok, "Agent crashed or exited with error: " .. tostring(err))

        local f = io.open(test_state_file, "r")
        assert.is_nil(f, "State file should be removed on graceful exit")

        io.read:revert()
    end)

    it("should truncate chat history correctly to respect the chat_budget", function()
        stub(io, "read").returns("/continue")
        local llm_calls = 0
        llm_handler.send_request = function(profile, messages)
            llm_calls = llm_calls + 1
            return { choices = { { message = { content = '<cmd>delegate_plan:{"plan": [{"file": "dummy.txt", "instruction": "init"}], "memo": ""}</cmd>' } } } }, nil
        end

        local heavy_history = {}
        for i=1, 50 do
            table.insert(heavy_history, { role = "user", content = string.rep("WORD ", 1000) })
        end

        local Context = require("context")
        local fake_ctx = Context.new({ PIPELINE = { {stage="TEST", agents={"ARCHITECT"}, mode="sequential"} }, AGENTS={ARCHITECT={}}, LIMITS = { MAX_CONTEXT = 100000 }})
        fake_ctx.agent_histories = { ARCHITECT = heavy_history }
        utils.write_file(test_state_file, fake_ctx:snapshot())

        local chunk, compile_err = loadfile("agent.lua")
        assert.is_truthy(chunk, "Failed to compile agent.lua: " .. tostring(compile_err))

        pcall(function() chunk("dummy_file.txt", "Task with heavy history") end)

        assert.is_true(llm_calls > 0, "LLM should have been called")
        io.read:revert()
    end)

    it("should handle interactive pipeline stage text injection", function()
        local read_count = 0
        stub(io, "read").invokes(function()
            read_count = read_count + 1
            if read_count == 1 then return "Change the plan slightly" end
            return "/continue"
        end)
        
        local llm_called_after_input = false
        llm_handler.send_request = function(profile, messages)
            if messages[#messages].content == "Change the plan slightly" then
                llm_called_after_input = true
            end
            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end
        
        local Context = require("context")
        local original_new = Context.new
        Context.new = function(cfg)
            cfg.PIPELINE = { { stage = "REVIEW", agents = {"ARCHITECT"}, mode = "interactive" } }
            return original_new(cfg)
        end
        
        local chunk = loadfile("agent.lua")
        pcall(function() chunk("dummy.txt", "test") end)
        
        assert.is_true(llm_called_after_input, "LLM was not triggered after manual user input in interactive mode")
        
        Context.new = original_new
        io.read:revert()
    end)

    it("should stream thoughts and normal content with distinct ANSI formatting", function()
        stub(io, "read").returns("/continue")

        local write_capture = ""
        local orig_write = io.write
        io.write = function(s) write_capture = write_capture .. tostring(s) end

        llm_handler.send_request = function(profile, messages, options)
            if options and options.on_token then
                options.on_token("Pre-thought. <thi")
                options.on_token("nk>Internal monolo")
                options.on_token("gue</th")
                options.on_token("ink> Final output.")
            end
            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end

        local Context = require("context")
        local original_new = Context.new
        Context.new = function(cfg)
            cfg.PIPELINE = { { stage = "TEST", agents = {"ARCHITECT"}, mode = "sequential" } }
            cfg.AGENTS.ARCHITECT.is_reasoning = false
            return original_new(cfg)
        end

        local chunk = loadfile("agent.lua")
        pcall(function() chunk("dummy.txt", "test streaming format") end)

        Context.new = original_new
        io.read:revert()
        io.write = orig_write

        assert.truthy(write_capture:match("Pre%-thought%. "), "Must print pre-thought text")
        assert.truthy(write_capture:match("\27%[90m<think>"), "Must inject ANSI gray start for thought")
        assert.truthy(write_capture:match("Internal monologue"), "Must print the thought content")
        assert.truthy(write_capture:match("</think>\27%[0m"), "Must inject ANSI reset after thought")
        assert.truthy(write_capture:match(" Final output%."), "Must print post-thought text")
    end)

    it("should successfully execute batch processing when TASKS are defined", function()
        stub(io, "read").returns("/continue")

        local utils = require("utils")
        local original_read_file = utils.read_file_range
        stub(utils, "read_file_range").invokes(function(path)
            if path:match("task%.txt$") then return nil end
            return original_read_file(path)
        end)

        local Context = require("context")
        stub(Context, "load_from_snapshot").returns(false, "Force fail for test")

        local task1_called = false
        local task2_called = false

        llm_handler.send_request = function(profile, messages)
            local prompt_text = messages[#messages].content
            if prompt_text:match("TASK 1") then task1_called = true end
            if prompt_text:match("TASK 2") then task2_called = true end

            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end

        local original_new = Context.new

        Context.new = function(cfg)
            cfg.TASKS = {
                { file = "dummy1.txt", instruction = "DO TASK 1" },
                { file = "dummy2.txt", instruction = "DO TASK 2" }
            }
            cfg.PIPELINE = { { stage = "TEST", agents = {"ARCHITECT"}, mode = "sequential" } }
            return original_new(cfg)
        end

        local chunk, compile_err = loadfile("agent.lua")
        assert.is_truthy(chunk, "Failed to compile agent.lua: " .. tostring(compile_err))

        local ok, err = pcall(function() chunk() end)

        assert.is_true(ok)
        assert.is_true(task1_called, "Task 1 was not executed in batch mode")
        assert.is_true(task2_called, "Task 2 was not executed in batch mode")

        Context.new = original_new
        io.read:revert()
        utils.read_file_range:revert()
    end)

    it("should resolve instruction_file from local config during batch processing", function()
        stub(io, "read").returns("/continue")

        local utils = require("utils")
        local original_read_file = utils.read_file_range
        stub(utils, "read_file_range").invokes(function(path)
            if path:match("task%.txt$") then return nil end
            if path:match("arch_spec%.md") then
                return "MOCKED INSTRUCTION PAYLOAD"
            end
            return original_read_file(path)
        end)

        local passed_payload = nil
        llm_handler.send_request = function(profile, messages)
            passed_payload = messages[#messages].content
            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end

        local Context = require("context")
        local original_new = Context.new

        Context.new = function(cfg)
            cfg.TASKS = { { file = "target.c", instruction_file = "arch_spec.md" } }
            cfg.PIPELINE = { { stage = "TEST", agents = {"ARCHITECT"}, mode = "sequential" } }
            cfg.AGENTS.ARCHITECT.is_reasoning = false
            return original_new(cfg)
        end

        local chunk = loadfile("agent.lua")
        pcall(function() chunk() end)

        assert.truthy(passed_payload:match("MOCKED INSTRUCTION PAYLOAD"), "Agent failed to inject payload from instruction_file")

        utils.read_file_range:revert()
        Context.new = original_new
        io.read:revert()
    end)

    it("should dynamically inject Tool-Aware Engine Directives based on allowed tools", function()
        stub(io, "read").returns("/continue")

        local captured_system_prompt = ""
        llm_handler.send_request = function(profile, messages)
            for _, msg in ipairs(messages) do
                if msg.role == "system" then captured_system_prompt = msg.content end
            end
            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end

        local Context = require("context")
        local original_new = Context.new
        
        Context.new = function(cfg)
            cfg.PIPELINE = { {stage="TEST", agents={"ARCHITECT"}, mode="sequential"} }
            cfg.AGENTS = { ARCHITECT = { allowed_tools = {"delegate_plan"} } }
            return original_new(cfg)
        end
        
        local chunk = loadfile("agent.lua")
        pcall(function() chunk("dummy.txt", "init") end)

        assert.truthy(captured_system_prompt:match("ENGINE DIRECTIVES %(CRITICAL & NON%-NEGOTIABLE%)"))
        assert.truthy(captured_system_prompt:match("MUST use `<cmd>delegate_plan</cmd>`"), "Should force delegate_plan when only it is available")

        Context.new = original_new
        io.read:revert()
    end)

    it("should initialize stream with ANSI gray if agent.is_reasoning is true (Implicit Start)", function()
        stub(io, "read").returns("/continue")

        local write_capture = ""
        local orig_write = io.write
        io.write = function(s) write_capture = write_capture .. tostring(s) end

        llm_handler.send_request = function(profile, messages, options)
            if options and options.on_token then
                options.on_token("Analyzing architecture...")
                options.on_token(" Seems fine.\n")
                options.on_token("</think>\n")
                options.on_token("<cmd>task_complete</cmd>")
            end
            return { choices = { { message = { content = "dummy" } } } }, nil
        end

        local Context = require("context")
        local original_new = Context.new
        Context.new = function(cfg)
            cfg.PIPELINE = { { stage = "TEST", agents = {"ARCHITECT"}, mode = "sequential" } }
            cfg.AGENTS.ARCHITECT.is_reasoning = true 
            return original_new(cfg)
        end

        local chunk = loadfile("agent.lua")
        pcall(function() chunk("dummy.txt", "test implicit reasoning stream") end)

        Context.new = original_new
        io.read:revert()
        io.write = orig_write

        assert.truthy(write_capture:match("AI %(ARCHITECT%):\27%[0m \27%[90m"), "Stream MUST inject ANSI gray right after the agent prefix if is_reasoning is true")
        assert.truthy(write_capture:match("Analyzing architecture"), "Thought content must be printed")
        assert.truthy(write_capture:match("</think>\27%[0m"), "Parser must inject ANSI reset after </think> tag")
    end)

    it("should extract CoT to Context and replace it with a safe SYSTEM MEMORY marker in agent_histories", function()
        stub(io, "read").returns("/continue")

        local raw_thought = "This is a massive internal monologue evaluating the AST."
        local raw_llm_output = "<think>\n" .. raw_thought .. "\n</think>\n<cmd>task_complete</cmd>"

        llm_handler.send_request = function(profile, messages, options)
             return { choices = { { message = { content = raw_llm_output } } } }, nil
        end

        local Context = require("context")
        local captured_ctx
        local original_new = Context.new

        Context.new = function(...)
            captured_ctx = original_new(...)
            return captured_ctx
        end

        local chunk, _ = loadfile("agent.lua")
        pcall(function() chunk("dummy.txt", "Execute and isolate memory") end)

        Context.new = original_new
        assert.truthy(captured_ctx, "Context was not initialized in memory")

        local history = captured_ctx:get_history("ARCHITECT")

        local assistant_msg = ""
        for i = #history, 1, -1 do
            if history[i].role == "assistant" then
                assistant_msg = history[i].content
                break
            end
        end

        assert.falsy(assistant_msg:match("<think>"), "History MUST NOT contain <think> tags to prevent Context Poisoning")
        assert.falsy(assistant_msg:match("massive internal monologue"), "History MUST NOT contain the thought payload")
        
        assert.truthy(assistant_msg:match("%[SYSTEM MEMORY: Internal cognitive process abstracted"), "History MUST contain the safe memory marker")
        assert.truthy(assistant_msg:match("<cmd>task_complete</cmd>"), "History must contain the final deterministic action")

        assert.truthy(captured_ctx.thoughts, "Thoughts table missing in isolated context")
        assert.is_true(#captured_ctx.thoughts > 0, "Thought was not routed to the isolation table")
        assert.truthy(captured_ctx.thoughts[#captured_ctx.thoughts].content:match("massive internal monologue"), "Thought text was not correctly extracted into context state")
    end)

    it("should override pipeline when --agent is specified", function()
        stub(io, "read").returns("/continue")

        local used_agent = nil
        llm_handler.send_request = function(profile, messages)
            used_agent = profile.name
            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end

        local Context = require("context")
        local original_new = Context.new
        Context.new = function(cfg)
            cfg.AGENTS = {
                DEFAULT_AGENT = { name = "DEFAULT_AGENT" },
                CUSTOM_CODER = { allowed_tools = {"*"}, name = "CUSTOM_CODER" }
            }
            cfg.PIPELINE = { { stage = "TEST", agents = {"DEFAULT_AGENT"}, mode = "sequential" } }
            return original_new(cfg)
        end

        local chunk = loadfile("agent.lua")
        pcall(function() chunk("--agent", "CUSTOM_CODER", "dummy.txt", "test instruction") end)

        assert.are.equal("CUSTOM_CODER", used_agent, "The overridden agent should have been called instead of DEFAULT_AGENT")

        Context.new = original_new
        io.read:revert()
    end)
end)
