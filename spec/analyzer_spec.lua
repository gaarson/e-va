-- spec/analyzer_spec.lua
local Analyzer = require("analyzer")
local Context = require("context")

describe("Analyzer Subsystem (Heuristic JSON Parsing)", function()
    local ctx
    local mock_llm
    local original_print
    local original_write
    
    -- Динамическая генерация Markdown-символов (backticks) для защиты парсера UI
    local mkd_block = string.char(96, 96, 96) 
    
    before_each(function()
        ctx = Context.new({
            PROJECT_ROOT = "/tmp/mock",
            LLM_SCOUT = { name = "SCOUT" },
            PROMPT_ANALYSIS = "System Prompt"
        })
        
        ctx.update_file_tree = function(self, tree)
            self.file_tree = tree
        end
        ctx.file_tree = "mock_file.lua"
        
        mock_llm = {
            send_request = function() return {}, nil end,
            extract_content = function() return "" end
        }
        
        original_print = _G.print
        original_write = io.write
        _G.print = function() end
        io.write = function() end
    end)

    after_each(function()
        _G.print = original_print
        io.write = original_write
    end)

    it("should establish default Identity on network failure", function()
        mock_llm.send_request = function() return nil, "HTTP 500" end
        
        local result = Analyzer.run(ctx, mock_llm)
        
        assert.is_false(result)
        assert.is_table(ctx.identity)
        assert.are.equal("Developer", ctx.identity.persona)
    end)

    it("should successfully extract and parse raw JSON payload", function()
        local valid_json = '{"persona": "Backend Engineer", "type": "API", "stack": ["Go"]}'
        mock_llm.extract_content = function() return valid_json end
        
        local result = Analyzer.run(ctx, mock_llm)
        
        assert.is_true(result)
        assert.are.equal("Backend Engineer", ctx.identity.persona)
        assert.are.equal("API", ctx.identity.type)
        assert.are.same({"Go"}, ctx.identity.stack)
    end)

    it("should safely bypass markdown code blocks and fix trailing commas", function()
        -- КРИТИЧЕСКИЙ ФИКС: Добавлено поле "type" для предотвращения падения string.format
        local dirty_payload = "Here is my analysis:\n" .. 
                              mkd_block .. "json\n" ..
                              '{"persona": "Systems Hacker", "type": "Daemon", "stack": ["C", "Lua"],}\n' ..
                              mkd_block .. "\nEnjoy!"
                              
        mock_llm.extract_content = function() return dirty_payload end
        
        local result = Analyzer.run(ctx, mock_llm)
        
        assert.is_true(result)
        assert.are.equal("Systems Hacker", ctx.identity.persona)
        assert.are.equal("Daemon", ctx.identity.type)
        assert.are.same({"C", "Lua"}, ctx.identity.stack)
    end)
end)
