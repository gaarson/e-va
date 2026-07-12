-- Comprehensive tests for patcher.lua (Lua-level fuzzy patch engine)
-- Run with: ./run_tests.sh tools/__tests__/test_patcher.lua
local patcher = require("patcher")
-- Helper: create a mock ctx with knowledge_base
local function mock_ctx(content)
    return {
        knowledge_base = { ["test_file.lua"] = content },
        config = { PROJECT_ROOT = ".", CREATE_BACKUPS = false },
        file_states = {},
        add_file = function(self, path, c) self.knowledge_base[path] = c end,
        squash_last_mutation = function() end,
    }
end
-- Helper: simulate the patch tool handler
local function run_patch(patch_tool, args, ctx)
    local reg = { tools = {} }
    local function register(name, desc, usage, handler)
        reg.tools[name] = { exec = handler }
    end
    reg.register = register
    patch_tool.register(reg)
    return reg.tools["patch"].exec(args, ctx, "TEST_AGENT")
end
describe("patcher.apply_patch — Basic functionality", function()
    it("should apply a simple single-line replacement", function()
        local content = "local x = 1\nlocal y = 2\nlocal z = 3"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert.are.equal("local x = 99\nlocal y = 2\nlocal z = 3", new_content)
    end)
    it("should apply a multi-line replacement", function()
        local content = "function foo()\n    return 1\nend\nfunction bar()\n    return 2\nend"
        local patch = "<<<<<<< SEARCH\nfunction foo()\n    return 1\nend\n=======\nfunction foo()\n    return 42\nend\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("return 42"))
        assert(new_content:find("function bar"))
    end)
    it("should apply multiple patches in one call", function()
        local content = "local a = 1\nlocal b = 2\nlocal c = 3"
        local patch = "<<<<<<< SEARCH\nlocal a = 1\n=======\nlocal a = 10\n>>>>>>> REPLACE\n<<<<<<< SEARCH\nlocal c = 3\n=======\nlocal c = 30\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(2, changes)
        assert(new_content:find("local a = 10"))
        assert(new_content:find("local c = 30"))
    end)
    it("should handle insertion (empty SEARCH is rejected, but replacing a marker works)", function()
        local content = "START\nEND"
        local patch = "<<<<<<< SEARCH\nSTART\n=======\nSTART\nINSERTED_LINE\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("INSERTED_LINE"))
    end)
    it("should handle deletion (empty REPLACE)", function()
        local content = "KEEP\nDELETE_ME\nALSO_KEEP"
        local patch = "<<<<<<< SEARCH\nDELETE_ME\n=======\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(not new_content:find("DELETE_ME"))
        assert(new_content:find("KEEP"))
        assert(new_content:find("ALSO_KEEP"))
    end)
end)
describe("patcher.apply_patch — Fuzzy matching (whitespace tolerance)", function()
    it("should tolerate leading whitespace differences", function()
        local content = "    local x = 1\n    local y = 2"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local ok, new_content = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert(new_content:find("local x = 99"))
    end)
    it("should tolerate trailing whitespace differences", function()
        local content = "local x = 1   \nlocal y = 2"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local ok, new_content = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert(new_content:find("local x = 99"))
    end)
    it("should tolerate mixed tabs/spaces", function()
        local content = "\tlocal x = 1\n    local y = 2"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local ok, new_content = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert(new_content:find("local x = 99"))
    end)
end)
describe("patcher.apply_patch — Edge cases", function()
    it("should reject empty SEARCH block", function()
        local content = "some content"
        local patch = "<<<<<<< SEARCH\n\n=======\nsomething\n>>>>>>> REPLACE"
        local ok, err = patcher.apply_patch(content, patch)
        assert.are_false(ok)
        assert(err:find("empty or whitespace-only", 1, true))
    end)
    it("should reject zero-op patch (SEARCH == REPLACE)", function()
        local content = "local x = 1"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 1\n>>>>>>> REPLACE"
        local ok, err = patcher.apply_patch(content, patch)
        assert.are_false(ok)
        assert(err:find("EXACTLY identical", 1, true))
    end)
    it("should fail when block not found", function()
        local content = "local x = 1\nlocal y = 2"
        local patch = "<<<<<<< SEARCH\nlocal nonexistent = 999\n=======\nlocal replaced = 1\n>>>>>>> REPLACE"
        local ok, err = patcher.apply_patch(content, patch)
        assert.are_false(ok)
        assert(err:find("not found", 1, true))
    end)
    it("should detect AMBIGUOUS MATCH", function()
        local content = "local x = 1\nlocal y = 2\nlocal x = 1\nlocal z = 3"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local ok, err = patcher.apply_patch(content, patch)
        assert.are_false(ok)
        assert(err:find("AMBIGUOUS", 1, true))
    end)
    it("should resolve ambiguity with more context lines", function()
        local content = "local x = 1\nlocal y = 2\nlocal x = 1\nlocal z = 3"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\nlocal z = 3\n=======\nlocal x = 99\nlocal z = 3\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        -- Only the second occurrence should be replaced
        assert(new_content:find("local x = 1\nlocal y = 2"))
        assert(new_content:find("local x = 99\nlocal z = 3"))
    end)
    it("should handle missing closing >>>>>>> REPLACE (fallback)", function()
        local content = "local x = 1\nlocal y = 2"
        local patch = "<<<<<<< SEARCH\nlocal y = 2\n=======\nBBB_NEW"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("BBB_NEW"))
    end)
    it("should handle CRLF line endings", function()
        local content = "local x = 1\r\nlocal y = 2\r\nlocal z = 3"
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("local x = 99"))
    end)
    it("should handle empty content", function()
        local ok, err = patcher.apply_patch("", "some patch")
        assert.are_false(ok)
    end)
    it("should handle nil content", function()
        local ok, err = patcher.apply_patch(nil, "some patch")
        assert.are_false(ok)
        assert(err:find("No content provided", 1, true))
    end)
    it("should handle no valid blocks found", function()
        local content = "some content"
        local patch = "just some random text without any markers"
        local ok, err = patcher.apply_patch(content, patch)
        assert.are_false(ok)
        assert(err:find("No valid SEARCH/REPLACE blocks", 1, true))
    end)
end)
describe("patcher.apply_patch — Real-world scenarios", function()
    it("should patch a Lua function with proper indentation", function()
        local content = "local function calculate(a, b)\n    local sum = a + b\n    return sum\nend\nlocal function other()\n    return true\nend"
        local patch = "<<<<<<< SEARCH\nlocal function calculate(a, b)\n    local sum = a + b\n    return sum\nend\n=======\nlocal function calculate(a, b)\n    local product = a * b\n    return product\nend\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("local product = a * b", 1, true))
        assert(not new_content:find("local sum = a + b"))
        assert(new_content:find("local function other"))
    end)
    it("should patch a C struct definition", function()
        local content = "typedef struct {\n    int x;\n    int y;\n    int z;\n} Point3D;\nvoid draw(Point3D p) {\n    printf(\"%d,%d,%d\", p.x, p.y, p.z);\n}"
        local patch = "<<<<<<< SEARCH\ntypedef struct {\n    int x;\n    int y;\n    int z;\n} Point3D;\n=======\ntypedef struct {\n    float x;\n    float y;\n    float z;\n    float w;\n} Point4D;\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("float x"))
        assert(new_content:find("Point4D"))
    end)
    it("should handle patching near file boundaries (beginning)", function()
        local content = "#!/usr/bin/env lua\nlocal x = 1\nlocal y = 2"
        local patch = "<<<<<<< SEARCH\n#!/usr/bin/env lua\nlocal x = 1\n=======\n#!/usr/bin/env lua\nlocal x = 100\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("local x = 100"))
    end)
    it("should handle patching near file boundaries (end)", function()
        local content = "local a = 1\nlocal b = 2\nreturn a + b"
        local patch = "<<<<<<< SEARCH\nlocal b = 2\nreturn a + b\n=======\nlocal b = 2\nreturn a * b\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("return a * b", 1, true))
    end)
    it("should handle unicode content", function()
        local content = 'local greeting = "Привет мир"\nlocal name = "测试"'
        local patch = '<<<<<<< SEARCH\nlocal greeting = "Привет мир"\n=======\nlocal greeting = "Hello World"\n>>>>>>> REPLACE'
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("Hello World"))
    end)
    it("should handle very long lines", function()
        local long_line = "local data = " .. string.rep("x", 5000)
        local content = long_line .. "\nlocal next = 1"
        local patch = "<<<<<<< SEARCH\n" .. long_line .. "\n=======\nlocal data = nil\n>>>>>>> REPLACE"
        local ok, new_content, changes = patcher.apply_patch(content, patch)
        assert.are_true(ok)
        assert.are.equal(1, changes)
        assert(new_content:find("local data = nil"))
    end)
end)
describe("patch tool handler (tools/patch.lua) — Integration", function()
    local patch_tool = require("tools.patch")
    it("should reject empty args", function()
        local ctx = mock_ctx("content")
        local result = run_patch(patch_tool, "", ctx)
        assert(result.output:find("Invalid patch syntax", 1, true))
    end)
    it("should reject file not found", function()
        local ctx = mock_ctx(nil)
        ctx.knowledge_base = {}
        local patch = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local result = run_patch(patch_tool, "nonexistent_file.lua\n" .. patch, ctx)
        assert(result.output:find("not found", 1, true))
    end)
    it("should succeed with valid patch", function()
        local ctx = mock_ctx("local x = 1\nlocal y = 2")
        local patch_body = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local result = run_patch(patch_tool, "test_file.lua\n" .. patch_body, ctx)
        assert(result.output:find("SUCCESS", 1, true))
        assert.are.equal("MUTATION_SUCCESS", result.signal)
        assert.are.equal("RECENTLY_MODIFIED", ctx.file_states["test_file.lua"])
    end)
    it("should load file from disk if not in knowledge_base", function()
        local utils = require("utils")
        local tmpfile = os.tmpname()
        local f = io.open(tmpfile, "w")
        f:write("local x = 1\nlocal y = 2")
        f:close()
        local ctx = {
            knowledge_base = {},
            config = { PROJECT_ROOT = ".", CREATE_BACKUPS = false },
            file_states = {},
            add_file = function(self, path, c) self.knowledge_base[path] = c end,
            squash_last_mutation = function() end,
        }
        local patch_body = "<<<<<<< SEARCH\nlocal x = 1\n=======\nlocal x = 99\n>>>>>>> REPLACE"
        local result = run_patch(patch_tool, tmpfile .. "\n" .. patch_body, ctx)
        assert(result.output:find("SUCCESS", 1, true))
        os.remove(tmpfile)
    end)
end)
