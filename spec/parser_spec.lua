local parser = require("parser")

describe("Parser Module - Depth-Tracking State Machine", function()
    
    describe("extract_commands()", function()
        
        it("should extract a single simple command", function()
            local content = "System thought process... <cmd>task_complete</cmd> Wait, more thoughts."
            local iterator = parser.extract_commands(content)
            
            assert.are.equal("task_complete", iterator())
            assert.is_nil(iterator()) -- Больше команд нет
        end)

        it("should extract multiple sequential commands", function()
            local content = "<cmd>read_file:main.c</cmd>\nSome text\n<cmd>search:malloc</cmd>"
            local iterator = parser.extract_commands(content)
            
            assert.are.equal("read_file:main.c", iterator())
            assert.are.equal("search:malloc", iterator())
            assert.is_nil(iterator())
        end)

        it("CRITICAL: should handle nested cmd tags correctly (The Bugfix)", function()
            -- Имитируем полезную нагрузку, которая ломала старый regex-парсер
            local content = [[
<cmd>create_file:test.lua
local function do_something()
    print("<cmd>nested_fake_command</cmd>")
end
</cmd>]]
            local iterator = parser.extract_commands(content)
            local payload = iterator()
            
            assert.is_not_nil(payload)
            -- Убеждаемся, что мы захватили ВЕСЬ блок, включая внутренние теги
            assert.truthy(payload:match("create_file:test.lua"))
            assert.truthy(payload:match("<cmd>nested_fake_command</cmd>"))
            
            -- Убеждаемся, что парсер не воспринял внутренний тег как вторую команду
            assert.is_nil(iterator())
        end)

        it("should ignore malformed/unclosed tags safely", function()
            local content = "<cmd>valid_command</cmd> and then an <cmd>unclosed_tag_here"
            local iterator = parser.extract_commands(content)
            
            assert.are.equal("valid_command", iterator())
            assert.is_nil(iterator()) -- Незакрытый тег игнорируется
        end)

        it("should handle empty or nil content gracefully", function()
            local iter_empty = parser.extract_commands("")
            assert.is_nil(iter_empty())
            
            local iter_nil = parser.extract_commands(nil)
            assert.is_nil(iter_nil())
        end)

    end)

    describe("reconstruct_commands()", function()
        
        it("should correctly wrap array of commands back into string format", function()
            local commands = {"task_complete", "read_file:utils.lua"}
            local result = parser.reconstruct_commands(commands)
            
            local expected = "<cmd>task_complete</cmd>\n<cmd>read_file:utils.lua</cmd>"
            assert.are.equal(expected, result)
        end)

        it("should return empty string for empty input", function()
            assert.are.equal("", parser.reconstruct_commands({}))
            assert.are.equal("", parser.reconstruct_commands(nil))
        end)

    end)

end)
