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
        
        assert.are.equal("'rm -rf /; echo '\\''owned'\\'''", escaped)
    end)

    it("copy_file should strictly duplicate binary and text data", function()
        utils.write_file(test_src, "syscall test data\x00\x01\x02")
        
        local ok, err = utils.copy_file(test_src, test_dest)
        assert.is_true(ok)
        assert.is_nil(err)

        local content = utils.read_file_range(test_dest)
        assert.are.equal("syscall test data\x00\x01\x02", content)
    end)

    describe("explore_directory (with line counts)", function()
        it("should include line counts for files and slashes for directories", function()
            local mock_p = {
                read = function() return "src/main.c\nsrc/components" end,
                close = function() end
            }
            stub(io, "popen").returns(mock_p)
            
            stub(os, "execute").invokes(function(cmd)
                if cmd:match("components") then return 0 else return 1 end
            end)

            stub(utils, "count_lines_fast").returns(42)

            local tree = utils.explore_directory("/fake/root", "src", 1)

            assert.truthy(tree:match("src/main.c %(42 lines%)"), "Files must include line counts")
            assert.truthy(tree:match("src/components/"), "Directories must have trailing slashes and NO line counts")

            io.popen:revert()
            os.execute:revert()
            utils.count_lines_fast:revert()
        end)
    end)
end)
