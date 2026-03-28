local utils = require("utils")
local os = require("os")
local io = require("io")

describe("utils I/O operations", function()
    it("write_file should return true on successful write", function()
        local mock_file = {
            write = function() return true end,
            close = function() end
        }
        local orig_open = io.open
        io.open = function() return mock_file end

        local ok, err = utils.write_file("dummy.txt", "content")

        assert.is_true(ok)
        assert.is_nil(err)

        io.open = orig_open
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

            local content, err = utils.read_file_range("/dummy_huge.log")
            assert.is_nil(err)
            assert.truthy(content:match("HEAD_CONTENT"))
            assert.truthy(content:match("TAIL_CONTENT"))
            assert.truthy(content:match("%[SNIPPED %d+ BYTES%]"))
        end)
    end)

    describe("Missing Coverage branches for Utils", function()
        local test_file = "utils_test_tmp.txt"
        
        after_each(function() os.remove(test_file) end)

        it("replace_lines should handle out of bounds and normal replacement", function()
            utils.write_file(test_file, "line1\nline2\nline3\n")
            
            -- Normal replace
            local ok = utils.replace_lines(test_file, 2, 2, "NEW_LINE2")
            assert.is_true(ok)
            local content = utils.read_file_range(test_file)
            assert.truthy(content:match("NEW_LINE2"))

            -- Out of bounds
            local ok_err, err = utils.replace_lines(test_file, 10, 15, "x")
            assert.is_false(ok_err)
            assert.truthy(err:match("Invalid line range"))

            -- Missing file
            local ok_err2, err2 = utils.replace_lines("nonexistent_file.txt", 1, 1, "x")
            assert.is_false(ok_err2)
            assert.truthy(err2:match("No such file") or err2:match("No such") or err2:match("Error"))
        end)

        it("read_file_numbered and read_file_lines should format correctly", function()
            utils.write_file(test_file, "a\nb\nc")
            local content, idx = utils.read_file_numbered(test_file, 2, 2)
            assert.truthy(content:match("2 | b"))
            assert.are.equal(3, idx)

            local content2, idx2 = utils.read_file_lines(test_file, 1, 1)
            assert.truthy(content2:match("1| a"))
            
            local content3, err3 = utils.read_file_lines(test_file, 10, 10)
            assert.is_nil(content3)
            assert.truthy(err3:match("Range outside"))
            
            local fail_num = utils.read_file_numbered("bad.txt")
            assert.is_nil(fail_num)
        end)
        
        it("cleanup_backups executes command", function()
            local orig_exec = os.execute
            os.execute = function() return 0 end
            
            local res = utils.cleanup_backups("/tmp")
            assert.is_true(res)
            
            os.execute = orig_exec
        end)
        
        it("copy_file handles dest open fail", function()
            utils.write_file(test_file, "data")
            local original_open = io.open
            io.open = function(path, mode)
                if mode == "wb" then return nil, "access denied" end
                return original_open(path, mode)
            end
            
            local ok, err = utils.copy_file(test_file, "dest.txt")
            assert.is_false(ok)
            assert.truthy(err:match("Dest open failed"))
            
            io.open = original_open
        end)
    end)
end)
