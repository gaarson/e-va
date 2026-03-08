-- spec/backup_spec.lua
local utils = require("utils")
local os = require("os")
local io = require("io")

describe("Backup Management", function()
    local test_file = "test_target.txt"
    local bak_file = test_file .. ".bak"

    before_each(function()
        utils.write_file(test_file, "original content")
    end)

    after_each(function()
        os.remove(test_file)
        os.remove(bak_file)
    end)

    it("should restore a file from its .bak extension", function()
        utils.copy_file(test_file, bak_file)
        utils.write_file(test_file, "corrupted content")
        
        local ok, err = utils.restore_backup(test_file)
        assert.is_true(ok)
        
        local restored = utils.read_file_range(test_file)
        assert.are.equal("original content", restored)
    end)

    it("should fail gracefully if .bak does not exist", function()
        local ok, err = utils.restore_backup("nonexistent.txt")
        assert.is_false(ok)
        assert.are.equal("Backup not found", err)
    end)
end)
