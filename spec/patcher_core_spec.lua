-- spec/patcher_core_spec.lua
-- Загружаем скомпилированную библиотеку C
local patcher_core = require("patcher_core")

describe("C Native Module: patcher_core", function()
    
    local content = {
        "local function calculate_sum(a, b)",
        "    local result = a + b",
        "    return result",
        "end",
        "",
        "local function calculate_diff(a, b)",
        "    local result = a - b",
        "    return result",
        "end"
    }

    it("should find an exact match and return 1-based indices", function()
        local search = {
            "local function calculate_diff(a, b)",
            "    local result = a - b",
            "    return result",
            "end"
        }
        
        local start_idx, end_idx, err = patcher_core.find_unique_fuzzy_block(content, search)
        
        assert.is_nil(err)
        assert.are.equal(6, start_idx)
        assert.are.equal(9, end_idx)
    end)

    it("should perform zero-allocation fuzzy matching (ignoring whitespace)", function()
        -- Строки поиска искорежены: убраны пробелы, табуляции сбиты
        local search_fuzzy = {
            "localfunctioncalculate_diff(a,b)",
            "localresult=a-b",
            "returnresult",
            "end"
        }
        
        local start_idx, end_idx, err = patcher_core.find_unique_fuzzy_block(content, search_fuzzy)
        
        assert.is_nil(err)
        assert.are.equal(6, start_idx)
        assert.are.equal(9, end_idx)
    end)

    it("should trigger AMBIGUOUS MATCH on multiple occurrences", function()
        local search_ambiguous = {
            "    return result",
            "end"
        }
        
        local start_idx, end_idx, err = patcher_core.find_unique_fuzzy_block(content, search_ambiguous)
        
        assert.is_nil(start_idx)
        assert.is_nil(end_idx)
        assert.truthy(err:match("AMBIGUOUS MATCH"))
    end)

    it("should handle error gracefully if search block is not found", function()
        local search_missing = {
            "local function do_magic()",
            "end"
        }
        
        local start_idx, end_idx, err = patcher_core.find_unique_fuzzy_block(content, search_missing)
        
        assert.is_nil(start_idx)
        assert.is_nil(end_idx)
        assert.are.equal("Block not found", err)
    end)
end)
