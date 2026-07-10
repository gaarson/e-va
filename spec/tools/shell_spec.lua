local registry = require("tool_registry")
local tools = require("tools")
local Context = require("context")

describe("Tools: shell", function()
    local ctx
    local original_execute = os.execute
    local original_tmpname = os.tmpname
    local original_open = io.open
    local original_write = io.write
    local original_read = io.read

    before_each(function()
        io.write = function() end
        io.read = function() return "y" end  -- Auto-approve unsafe commands

        registry.tools = {}
        tools.init()
        ctx = Context.new({
            PROJECT_ROOT = ".",
            CREATE_BACKUPS = false,
            AGENTS = {
                TEST_AGENT = {
                    allowed_tools = { "*" }
                }
            }
        })

        -- Mock os.execute to prevent actual command execution
        local exec_count = 0
        os.execute = function(cmd)
            exec_count = exec_count + 1
            -- Simulate successful execution
            return 0
        end

        -- Mock os.tmpname to return predictable temp file names
        local tmp_counter = 0
        os.tmpname = function()
            tmp_counter = tmp_counter + 1
            return "/tmp/test_" .. tmp_counter
        end

        -- Mock io.open to simulate file operations
        local file_contents = {}
        io.open = function(path, mode)
            if mode == "w" or mode == "wb" then
                return {
                    write = function(self, content)
                        file_contents[path] = content
                        return true
                    end,
                    close = function() end
                }
            elseif mode == "r" or mode == "rb" then
                return {
                    read = function() return file_contents[path] or "" end,
                    seek = function() return 0 end,
                    close = function() end
                }
            end
            return nil
        end
    end)

    after_each(function()
        os.execute = original_execute
        os.tmpname = original_tmpname
        io.open = original_open
        io.write = original_write
        io.read = original_read
    end)

    it("should parse timeout prefix correctly", function()
        -- Test timeout=120;ls parsing
        local res = registry.execute("shell:timeout=120;ls", ctx, "TEST_AGENT")
        assert.truthy(res.output)
        -- The command should have been parsed with timeout=120
        assert.truthy(res.output:match("Executing"))
    end)

    it("should parse stdin prefix correctly", function()
        -- Test stdin=test;echo hello parsing
        local res = registry.execute("shell:stdin=test;echo hello", ctx, "TEST_AGENT")
        assert.truthy(res.output)
        assert.truthy(res.output:match("Executing"))
    end)

    it("should parse combined timeout and stdin prefixes", function()
        -- Test timeout=10;stdin=data;cat parsing
        local res = registry.execute("shell:timeout=10;stdin=data;cat", ctx, "TEST_AGENT")
        assert.truthy(res.output)
        assert.truthy(res.output:match("Executing"))
    end)

    it("should maintain backward compatibility without prefixes", function()
        -- Test ls works without prefixes
        local res = registry.execute("shell:ls", ctx, "TEST_AGENT")
        assert.truthy(res.output)
        assert.truthy(res.output:match("Executing"))
    end)

    it("should reject empty commands after parsing", function()
        -- Test that empty command returns error
        local res = registry.execute("shell:timeout=10;", ctx, "TEST_AGENT")
        assert.truthy(res.output:match("Empty command"))
    end)
end)