local tool_executor = require("tool_executor")
local Context = require("context")
local utils = require("utils")
local os = require("os")

describe("Tool Executor Subsystem (State & Mutators)", function()
    local ctx
    local test_file = "test_create_spec.txt"

    before_each(function()
        -- Эмулируем конфиг и создаем изолированную песочницу
        ctx = Context.new({ PROJECT_ROOT = "." })
        os.remove(test_file)
        os.remove(test_file .. ".bak")
    end)

    after_each(function()
        os.remove(test_file)
        os.remove(test_file .. ".bak")
    end)


    it("should ALLOW create_file in CODING phase and create nested directories if needed", function()
        local action = "create_file:" .. test_file .. "\nlocal x = 42\nreturn x"
        local res = tool_executor.execute(action, ctx, "CODING")

        assert.truthy(res.output:match("SUCCESS"))

        local content = utils.read_file_range(test_file)
        assert.are.equal("local x = 42\nreturn x", content)
    end)

    it("should ALLOW patch and create_file in AUTONOMOUS phase and emit MUTATION_SUCCESS", function()
        utils.write_file(test_file, "line1\nline2")
        
        local action = "patch:" .. test_file .. "\n<<<<<<< SEARCH\nline1\n=======\nline3\n>>>>>>> REPLACE"
        local res = tool_executor.execute(action, ctx, "AUTONOMOUS")

        assert.truthy(res.output:match("SUCCESS"))
        assert.are.equal("MUTATION_SUCCESS", res.signal)
        
        local content = utils.read_file_range(test_file)
        assert.truthy(content:match("line3"))
    end)

    it("should cache search queries and prevent duplicate shell executions", function()
        -- Первый вызов (должен инициировать реальный поиск)
        local action1 = "search:todo_fixme"
        -- Заглушаем io.popen, чтобы не дергать реальный bash
        local mock_f = { read = function() return "Match found" end, close = function() end }
        stub(io, "popen").returns(mock_f)

        local res1 = tool_executor.execute(action1, ctx, "RESEARCH")
        assert.truthy(res1.output:match("Match found"))
        assert.stub(io.popen).was_called()

        io.popen:clear()

        -- Второй вызов с тем же запросом (должен удариться в кэш)
        local res2 = tool_executor.execute(action1, ctx, "RESEARCH")
        assert.truthy(res2.output:match("Skipped duplicate search"))
        assert.stub(io.popen).was_not_called()

        io.popen:revert()
    end)
end)
