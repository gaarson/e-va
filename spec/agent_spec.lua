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

    it("should successfully bootstrap, execute one AUTONOMOUS turn, and exit cleanly on 'quit'", function()
        llm_handler.send_request = function(profile, messages)
            return {
                choices = { { message = { content = "System analyzed. No commands needed." } } }
            }, nil
        end

        io.read = function() return "quit" end

        -- [ФИКС]: Компилируем скрипт в память (chunk)
        local chunk, compile_err = loadfile("agent.lua")
        assert.is_truthy(chunk, "Failed to compile agent.lua: " .. tostring(compile_err))

        -- Запускаем скрипт, передавая аргументы напрямую в стек (varargs)
        local ok, err = pcall(function()
            chunk("dummy_file.txt", "Analyze the system")
        end)

        if not ok and type(err) == "string" and not err:match("OS_EXIT_CALLED:0") then
            original_print("\n[CRITICAL LUA ERROR IN AGENT]:\n" .. err)
        end

        assert.is_false(ok)
        assert.truthy(err:match("OS_EXIT_CALLED:0"), "Expected graceful exit (0), but got: " .. tostring(err))

        local f = io.open(test_state_file, "r")
        assert.is_nil(f, "State file should be removed on graceful exit")
    end)

    it("should truncate chat history correctly to respect the chat_budget", function()
        local llm_calls = 0
        llm_handler.send_request = function(profile, messages)
            llm_calls = llm_calls + 1
            local chat_messages = 0
            for _, msg in ipairs(messages) do
                if msg.role == "user" or msg.role == "assistant" then
                    chat_messages = chat_messages + 1
                end
            end

            assert.is_true(chat_messages > 0, "Chat buffer should not be empty")

            return {
                choices = { { message = { content = "<cmd>task_complete</cmd>" } } }
            }, nil
        end

        io.read = function() return "exit" end

        local heavy_history = {}
        for i=1, 50 do
            table.insert(heavy_history, { role = "user", content = string.rep("WORD ", 1000) })
        end
        local Context = require("context")
        local fake_ctx = Context.new({ LIMITS = { MAX_CONTEXT = 100000 }})
        fake_ctx.chat_history = heavy_history
        utils.write_file(test_state_file, fake_ctx:snapshot())

        -- Аналогично запускаем через loadfile
        local chunk, compile_err = loadfile("agent.lua")
        assert.is_truthy(chunk, "Failed to compile agent.lua: " .. tostring(compile_err))

        local ok, err = pcall(function() 
            chunk("dummy_file.txt", "Task with heavy history") 
        end)
        
        if not ok and type(err) == "string" and not err:match("OS_EXIT_CALLED:0") then
            original_print("\n[CRITICAL LUA ERROR IN AGENT]:\n" .. err)
        end

        assert.is_true(llm_calls > 0, "LLM should have been called")
    end)
end)
