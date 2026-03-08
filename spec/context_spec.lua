local Context = require("context")

describe("Context class", function()
    local mock_config
    local ctx

    before_each(function()
        -- Создаем изолированный конфиг перед каждым тестом
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
        -- Длина 12 символов, LIMITS.CHARS_PER_TOKEN = 4. Ожидаем 3 токена.
        local cost = ctx:estimate_tokens("123456789012")
        assert.are.equal(3, cost)
    end)
end)
