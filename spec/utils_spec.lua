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

  describe("deep_merge()", function()
    it("should recursively merge two tables", function()
      local base = { a = 1, b = { x = 10, y = 20 } }
      local specific = { b = { y = 99, z = 30 }, c = 2 }
      
      local merged = utils.deep_merge(base, specific)
      
      assert.are.equal(1, merged.a)
      assert.are.equal(10, merged.b.x)
      assert.are.equal(99, merged.b.y)
      assert.are.equal(30, merged.b.z)
      assert.are.equal(2, merged.c)    
    end)
    
    it("should handle nil inputs gracefully", function()
      local base = { a = 1 }
      local merged = utils.deep_merge(base, nil)
      assert.are.equal(1, merged.a)
      
      local merged2 = utils.deep_merge(nil, base)
      assert.are.equal(1, merged2.a)
    end)
  end)

end)
