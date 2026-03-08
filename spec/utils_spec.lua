local utils = require("utils")

describe("utils module", function()
  describe("trim()", function()
    it("should remove leading and trailing whitespace", function()
      assert.are.equal("hello", utils.trim("  hello  "))
      assert.are.equal("hello world", utils.trim("\t hello world \n"))
    end)

    it("should handle nil gracefully", function()
      assert.are.equal("", utils.trim(nil))
    end)
  end)

  describe("normalize_path()", function()
    it("should strip path/file prefixes and quotes", function()
      local root = "/home/ruser/projects/E-va"
      assert.are.equal("src/main.c", utils.normalize_path(root, "path: 'src/main.c'"))
      assert.are.equal("src/main.c", utils.normalize_path(root, 'file="src/main.c"'))
    end)

    it("should remove project root if path is absolute", function()
      local root = "/home/projects/E-va"
      local absolute = "/home/projects/E-va/config.lua"
      assert.are.equal("config.lua", utils.normalize_path(root, absolute))
    end)
  end)

end)
