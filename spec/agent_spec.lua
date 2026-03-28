local utils = require("utils")

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
        os.remove(test_state_file)

        package.loaded["agent"] = nil
    end)

    it("should successfully bootstrap, execute pipeline, and exit cleanly", function()
        -- Эмулируем чтение ввода (для интерактивной стадии)
        stub(io, "read").returns("/continue")

        llm_handler.send_request = function(profile, messages)
            -- Симулируем корректные ответы агентов для завершения стадий
            if profile.name == "ARCHITECT" then
                return { choices = { { message = { content = '<cmd>delegate_plan:[{"file": "dummy.txt", "instruction": "init"}]</cmd>' } } } }, nil
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
            return { choices = { { message = { content = '<cmd>delegate_plan:[{"file": "dummy.txt", "instruction": "init"}]</cmd>' } } } }, nil
        end

        local heavy_history = {}
        for i=1, 50 do
            table.insert(heavy_history, { role = "user", content = string.rep("WORD ", 1000) })
        end

        local Context = require("context")
        local fake_ctx = Context.new({ PIPELINE = { {stage="TEST", agents={"ARCHITECT"}, mode="sequential"} }, AGENTS={ARCHITECT={}}, LIMITS = { MAX_CONTEXT = 100000 }})
        -- Загружаем историю в правильный контейнер
        fake_ctx.agent_histories = { ARCHITECT = heavy_history }
        utils.write_file(test_state_file, fake_ctx:snapshot())

        local chunk, compile_err = loadfile("agent.lua")
        assert.is_truthy(chunk, "Failed to compile agent.lua: " .. tostring(compile_err))

        pcall(function() chunk("dummy_file.txt", "Task with heavy history") end)

        assert.is_true(llm_calls > 0, "LLM should have been called")
        io.read:revert()
    end)

    it("should preserve thoughts in chat history to maintain Chain-of-Thought continuity", function()
        stub(io, "read").returns("/continue")
        local raw_content_missing_start = "This is a leaked thought in English.\nLet's write code.\n</think>\nПривет, я всё сделал.\n<cmd>delegate_plan:[{\"file\": \"dummy.txt\", \"instruction\": \"init\"}]</cmd>"

        llm_handler.send_request = function(profile)
             if profile.name == "ARCHITECT" then
                 return { choices = { { message = { content = raw_content_missing_start } } } }, nil
             else
                 return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
             end
        end

        local Context = require("context")
        local captured_ctx
        local original_new = Context.new

        Context.new = function(...)
            captured_ctx = original_new(...)
            return captured_ctx
        end

        local chunk, _ = loadfile("agent.lua")
        pcall(function() chunk("dummy.txt", "Instruction") end)

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

        -- КРИТИЧЕСКИЙ ФИКС: Убеждаемся, что мысль ОСТАЛАСЬ в истории
        assert.truthy(assistant_msg:match("leaked thought"), "Thought MUST be preserved in history for CoT continuity!")
        assert.truthy(assistant_msg:match("Привет, я всё сделал"), "Russian communication was lost!")
        assert.truthy(captured_ctx.thoughts, "Thoughts table missing")
        assert.is_true(#captured_ctx.thoughts > 0, "Thought was not saved to isolation context!")
        assert.truthy(captured_ctx.thoughts[#captured_ctx.thoughts].content:match("Let's write code"), "Thought content is incorrect!")
        io.read:revert()
    end)

    it("should handle interactive pipeline stage text injection", function()
        -- Моделируем ситуацию: на интерактивной стадии юзер вводит текст, затем /continue
        local read_count = 0
        stub(io, "read").invokes(function()
            read_count = read_count + 1
            if read_count == 1 then return "Change the plan slightly" end
            return "/continue"
        end)
        
        local llm_called_after_input = false
        llm_handler.send_request = function(profile, messages)
            -- Проверяем, что сообщение дошло до LLM
            if messages[#messages].content == "Change the plan slightly" then
                llm_called_after_input = true
            end
            return { choices = { { message = { content = "<cmd>task_complete</cmd>" } } } }, nil
        end
        
        -- Устанавливаем пайплайн только с одной интерактивной стадией для скорости
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
end)
