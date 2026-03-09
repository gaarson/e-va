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

    describe("read_file_range with large files", function()
        local original_open = io.open

        after_each(function()
            io.open = original_open
        end)

        it("should snip content for files exceeding MAX_FILE_SIZE (1MB)", function()
            local fake_size = 2 * 1024 * 1024 -- 2MB
            local mock_f = {
                seek = function(self, whence, offset)
                    if whence == "end" and not offset then return fake_size end
                    return 0
                end,
                read = function(self, bytes)
                    if bytes == 512 * 1024 then return "HEAD_CONTENT" end
                    if bytes == 10 * 1024 then return "TAIL_CONTENT" end
                    return "FULL_CONTENT"
                end,
                close = function() end
            }

            io.open = function(path, mode) return mock_f, nil end

            local content, err = require("utils").read_file_range("/dummy_huge.log")
            assert.is_nil(err)
            assert.truthy(content:match("HEAD_CONTENT"))
            assert.truthy(content:match("TAIL_CONTENT"))
            assert.truthy(content:match("%[SNIPPED %d+ BYTES%]"))
        end)
    end)
end)
