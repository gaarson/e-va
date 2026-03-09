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

    describe("Serialization and State Management", function()
        it("should correctly snapshot and restore full context state", function()
            ctx:add_file("core.c", "int main() {}")
            ctx.identity = { persona = "Kernel Hacker", type = "Daemon" }
            ctx.current_task_index = 2

            local state_json = ctx:snapshot()
            assert.truthy(state_json)
            assert.truthy(type(state_json) == "string")

            -- Создаем новый контекст и восстанавливаем в него данные
            local new_ctx = Context.new(mock_config)
            local ok, err = new_ctx:load_from_snapshot(state_json)

            assert.is_true(ok)
            assert.is_nil(err)
            assert.are.equal("int main() {}", new_ctx.knowledge_base["core.c"])
            assert.are.equal("Kernel Hacker", new_ctx.identity.persona)
            assert.are.equal(2, new_ctx.current_task_index)
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
            ctx:add_file("huge.txt", string.rep("A", 500)) -- 500 chars

            -- Имитируем, что target.txt сейчас в фокусе (is_target = true)
            ctx.execution_plan = { { file = "target.txt" } }
            ctx.current_task_index = 1

            -- Устанавливаем жесткий лимит в ~30 токенов
            local mem_block = ctx:get_memory_block(30)

            assert.truthy(mem_block:match("target%.txt %.*%[TARGET FILE %- EDIT THIS%]"))
            assert.truthy(mem_block:match("%[OMITTED %- OUT OF MEMORY%]"))
        end)
    end)
end)
