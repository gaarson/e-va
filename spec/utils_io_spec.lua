local utils = require("utils")

describe("utils I/O operations", function()
    it("write_file should return true on successful write", function()
        -- Перехватываем стандартную библиотеку io (Stubbing)
        local mock_file = {
            write = function() return true end,
            close = function() end
        }
        stub(io, "open").returns(mock_file)

        local ok, err = utils.write_file("dummy.txt", "content")
        
        assert.is_true(ok)
        assert.is_nil(err)
        assert.stub(io.open).was_called_with("dummy.txt", "wb")
        
        -- Возвращаем io.open в исходное состояние
        io.open:revert()
    end)
end)
