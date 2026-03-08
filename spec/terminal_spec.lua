-- spec/terminal_spec.lua
local tool_executor = require("tool_executor")
local Context = require("context")

describe("Terminal & Analytics Subsystem", function()
    local ctx

    before_each(function()
        ctx = Context.new({ PROJECT_ROOT = "." })
        ctx.identity = { persona = "Developer" }
    end)

    it("should execute whitelisted read-only commands without prompting", function()
        local res = tool_executor.execute("shell:echo 'system_ok'", ctx)
        assert.truthy(res.output:match("system_ok"))
    end)

    it("should block dangerous commands and prompt user (Deny scenario)", function()
        -- Мокаем ввод пользователя, имитируя отказ ("n")
        stub(io, "read").returns("n")
        -- Перехватываем io.write, чтобы не мусорить в консоль при тестах
        stub(io, "write")

        local res = tool_executor.execute("shell:rm -rf /tmp/test", ctx)

        assert.truthy(res.output:match("DENIED by user"))
        assert.stub(io.read).was_called()
        
        io.read:revert()
        io.write:revert()
    end)

    it("should allow dangerous commands if user confirms (Allow scenario)", function()
        -- Мокаем ввод пользователя, имитируя согласие ("y")
        stub(io, "read").returns("y")
        stub(io, "write")

        -- Используем безобидную команду, которой нет в whitelist
        local res = tool_executor.execute("shell:date +%s", ctx)

        assert.falsy(res.output:match("DENIED"))
        assert.truthy(res.output:match("%[SHELL STDOUT/STDERR%]"))
        assert.stub(io.read).was_called()
        
        io.read:revert()
        io.write:revert()
    end)
end)
