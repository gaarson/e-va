local logger = require("logger")
local io = require("io")

describe("Logger Subsystem", function()
    local original_stderr
    local original_print
    local print_capture = ""
    local stderr_capture = ""

    before_each(function()
        print_capture = ""
        stderr_capture = ""
        
        original_stderr = io.stderr
        original_print = _G.print
        
        io.stderr = {
            write = function(self, str)
                stderr_capture = stderr_capture .. (str or "")
            end
        }
        
        _G.print = function(...)
            local str = tostring(select(1, ...))
            print_capture = print_capture .. str
        end
    end)

    after_each(function()
        io.stderr = original_stderr
        _G.print = original_print
    end)

    it("should prevent stack overflow on cyclic table references", function()
        local a = { name = "node A" }
        local b = { name = "node B", parent = a }
        a.child = b

        logger.info("Cyclic test", a)

        -- КРИТИЧЕСКИЙ ФИКС: Учитываем, что строковые ключи обрамляются двойными кавычками
        assert.truthy(print_capture:match('%+"child"'))
    end)

    it("should properly format ERROR logs to stderr", function()
        logger.error("Critical failure", { code = 139 })
        
        -- КРИТИЧЕСКИЙ ФИКС: Используем .* для обхода невидимого ANSI-кода \27[0m
        assert.truthy(stderr_capture:match("%[ERROR%].*Critical failure"))
    end)
end)
