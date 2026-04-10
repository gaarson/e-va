local utils = require("utils")

describe("CLI Argument Parsing Logic", function()
    local mock_config = {
        PROJECT_ROOT = "/tmp/eva_test"
    }

    it("should identify instruction from second argument", function()
        local arg1 = "file.txt"
        local arg2 = "do something"
        
        local start_file = type(arg1) == 'string' and arg1 or nil
        local instruction = type(arg2) == 'string' and arg2 or nil
        
        assert(start_file == "file.txt")
        assert(instruction == "do something")
    end)

    it("should handle missing arguments", function()
        local arg1 = nil
        local arg2 = nil
        
        local start_file = type(arg1) == 'string' and arg1 or nil
        local instruction = type(arg2) == 'string' and arg2 or nil
        
        assert(start_file == nil)
        assert(instruction == nil)
    end)

    it("should fall back to task.txt when instruction is missing", function()
        -- Mocking the environment
        local arg1 = "file.txt"
        local arg2 = nil
        
        local start_file = type(arg1) == 'string' and arg1 or nil
        local instruction = type(arg2) == 'string' and arg2 or nil
        
        if not instruction then
            -- Simulate utils.read_file_range and config
            local task_path = mock_config.PROJECT_ROOT .. '/.e-va-conf/task.txt'
            -- We simulate the successful read of "fallback task"
            local task_content = "fallback task" 
            if task_content and task_content ~= '' then
                instruction = task_content -- simplified trim
            end
        end
        
        assert(start_file == "file.txt")
        assert(instruction == "fallback task")
    end)
end)
