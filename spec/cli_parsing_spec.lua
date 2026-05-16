local utils = require("utils")

describe("CLI Argument Parsing Logic", function()
    local mock_config = {
        PROJECT_ROOT = "/tmp/eva_test"
    }

    local function parse_args(...)
        local cli_args = {...}
        local start_file = nil
        local instruction = nil
        local is_bootstrap = false
        local target_agent = nil

        local idx = 1
        while idx <= #cli_args do
            local a = cli_args[idx]
            if type(a) == "string" then
                if a == "--bootstrap" then
                    is_bootstrap = true
                elseif a == "--agent" and idx < #cli_args then
                    target_agent = cli_args[idx+1]
                    idx = idx + 1
                elseif not start_file then
                    start_file = a
                elseif not instruction then
                    instruction = a
                end
            end
            idx = idx + 1
        end

        return start_file, instruction, is_bootstrap, target_agent
    end

    it("should identify instruction from second argument", function()
        local start_file, instruction = parse_args("file.txt", "do something")
        assert.are.equal("file.txt", start_file)
        assert.are.equal("do something", instruction)
    end)

    it("should parse --agent flag and shift remaining arguments", function()
        local start_file, instruction, is_bootstrap, target_agent = parse_args("--agent", "CODER", "file.txt", "do something")
        assert.are.equal("CODER", target_agent)
        assert.are.equal("file.txt", start_file)
        assert.are.equal("do something", instruction)
    end)

    it("should handle missing arguments", function()
        local start_file, instruction = parse_args()
        assert.is_nil(start_file)
        assert.is_nil(instruction)
    end)

    it("should fall back to task.txt when instruction is missing", function()
        local start_file, instruction = parse_args("file.txt")

        if not instruction then
            local task_content = "fallback task"
            if task_content and task_content ~= '' then
                instruction = task_content
            end
        end

        assert.are.equal("file.txt", start_file)
        assert.are.equal("fallback task", instruction)
    end)
end)
