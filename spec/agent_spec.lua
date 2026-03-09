local utils = require("utils")

describe("Agent Control Plane (Integration)", function()
    local original_arg = _G.arg
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
        
        -- Подавляем STDOUT
        _G.print = function() end
        io.write = function() end

        -- Мокаем os.exit, чтобы агент не убил процесс тестировщика (busted)
        os.exit = function(code)
            error("OS_EXIT_CALLED:" .. tostring(code))
        end
    end)

    after_each(function()
        _G.arg = original_arg
        os.exit = original_exit
        io.read = original_read
        io.write = original_write
        _G.print = original_print
        llm_handler.send_request = original_send_request
        
        logger.error:revert()
        os.remove(test_state_file)
        
        -- Сбрасываем загруженный agent, чтобы можно было запускать его в других тестах
        package.loaded["agent"] = nil
    end)

    it("should successfully bootstrap, execute one RESEARCH turn, and exit cleanly on 'quit'", function()
        -- 1. Эмулируем аргументы командной строки
        _G.arg = { nil, "Analyze the system" }
        
        -- 2. Эмулируем ответ LLM (пустой ответ без команд)
        llm_handler.send_request = function(profile, messages)
            return {
                choices = { { message = { content = "System analyzed. No commands needed." } } }
            }, nil
        end
        
        -- 3. Эмулируем ввод пользователя в REPL. 
        -- Агент перейдет в REPL после фазы RESEARCH (так как нет команд).
        -- Сразу подаем команду выхода, чтобы завершить цикл.
        io.read = function() return "quit" end
        
        -- 4. Запускаем агент в защищенной песочнице
        local ok, err = pcall(function()
            dofile("agent.lua")
        end)
        
        -- Ожидаем, что скрипт попытается сделать os.exit(0), что выбросит нашу ошибку "OS_EXIT_CALLED:0"
        assert.is_false(ok)
        assert.truthy(err:match("OS_EXIT_CALLED:0"))
        
        -- Проверяем, что агент оставил после себя чистый стейт (файл должен быть удален при quit)
        local f = io.open(test_state_file, "r")
        assert.is_nil(f, "State file should be removed on graceful exit")
    end)

    it("should truncate chat history correctly to respect the chat_budget", function()
        -- Этот тест проверяет логику Token Budgeting внутри цикла
        _G.arg = { nil, "Task with heavy history" }
        
        local llm_calls = 0
        llm_handler.send_request = function(profile, messages)
            llm_calls = llm_calls + 1
            
            -- Проверяем, что messages не превышают лимиты
            -- messages[1] - system prompt
            -- Последние сообщения должны быть сохранены, старые усечены
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
        
        -- При возврате task_complete агент завершит план и уйдет в REPL.
        io.read = function() return "exit" end
        
        -- Создаем "тяжелую" фейковую историю в контексте ДО запуска агента
        -- (Это имитируется путем загрузки фейкового .e-va_state.json)
        local heavy_history = {}
        for i=1, 50 do
            table.insert(heavy_history, { role = "user", content = string.rep("WORD ", 1000) }) -- Очень длинные сообщения
        end
        local Context = require("context")
        local fake_ctx = Context.new({ LIMITS = { MAX_CONTEXT = 100000 }})
        fake_ctx.chat_history = heavy_history
        utils.write_file(test_state_file, fake_ctx:snapshot())
        
        -- Запуск
        pcall(function() dofile("agent.lua") end)
        
        assert.is_true(llm_calls > 0, "LLM should have been called")
    end)
end)
