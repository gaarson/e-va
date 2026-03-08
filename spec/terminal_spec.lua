-- spec/terminal_spec.lua
local tool_executor = require("tool_executor")
local Context = require("context")

describe("Terminal & Analytics Subsystem", function()
    local ctx

    before_each(function()
        ctx = Context.new({ PROJECT_ROOT = "." })
        ctx.identity = { persona = "Developer" }
    end)

    it("should execute shell commands and capture stdout", function()
        -- Тестируем простейшую POSIX-команду
        local res = tool_executor.execute("shell:echo 'system_ok'", ctx)
        
        assert.truthy(res.output:match("system_ok"))
        assert.truthy(res.output:match("%[SHELL STDOUT/STDERR%]"))
    end)

    it("should dynamically mutate the persona via text prompt", function()
        local res = tool_executor.execute("set_persona:Linux Kernel Hacker", ctx)
        
        assert.are.equal("Linux Kernel Hacker", ctx.identity.persona)
        assert.truthy(res.output:match("changed to: Linux Kernel Hacker"))
    end)
    
    it("should truncate excessively large shell outputs to protect LLM context", function()
        -- Генерируем большой вывод
        local res = tool_executor.execute("shell:head -c 5000 /dev/zero | tr '\\0' 'A'", ctx)
        
        assert.is_true(#res.output <= 4100) -- 4000 chars + headers
        assert.truthy(res.output:match("%[TRUNCATED%]"))
    end)
end)
