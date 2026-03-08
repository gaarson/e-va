local utils = require("utils")
local os = require("os")

describe("Utils (Extended FS & Security)", function()
    local test_src = "test_src.txt"
    local test_dest = "test_dest.txt"

    after_each(function()
        os.remove(test_src)
        os.remove(test_dest)
    end)

    it("shell_quote should properly escape single quotes to prevent command injection", function()
        local payload = "rm -rf /; echo 'owned'"
        local escaped = utils.shell_quote(payload)
        
        -- Ожидаем строгую изоляцию POSIX-совместимого аргумента
        assert.are.equal("'rm -rf /; echo '\\''owned'\\'''", escaped)
    end)

    it("copy_file should strictly duplicate binary and text data", function()
        -- Подготавливаем файл с бинарным нулем (null byte)
        utils.write_file(test_src, "syscall test data\x00\x01\x02")
        
        local ok, err = utils.copy_file(test_src, test_dest)
        assert.is_true(ok)
        assert.is_nil(err)

        local content = utils.read_file_range(test_dest)
        assert.are.equal("syscall test data\x00\x01\x02", content)
    end)
end)
