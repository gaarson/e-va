-- spec/patcher_spec.lua
local patcher = require("patcher")

describe("Core Patcher Subsystem", function()
    
    -- Базовый код для тестирования (mock file content)
    local source_code = [[
local function calculate_sum(a, b)
    local result = a + b
    return result
end

local function calculate_diff(a, b)
    local result = a - b
    return result
end
]]

    it("1. [STABLE] Should apply a perfectly matched patch block", function()
        local patch = [[
<<<<<<< SEARCH
local function calculate_sum(a, b)
    local result = a + b
    return result
end
=======
local function calculate_sum(a, b)
    -- Added bounds checking
    if not a or not b then return 0 end
    return a + b
end
>>>>>>> REPLACE
]]
        local ok, modified_code, changes_count = patcher.apply_patch(source_code, patch)
        
        assert.is_true(ok)
        assert.are.equal(1, changes_count)
        assert.truthy(modified_code:match("bounds checking"))
        assert.truthy(modified_code:match("if not a or not b then return 0 end"))
    end)

    it("2. [FUZZY] Should apply patch even with broken indentation/whitespaces", function()
        -- Имитируем ситуацию, когда LLM "съел" пробелы
        local patch = [[
<<<<<<< SEARCH
localfunction calculate_sum(a,b)
local result=a+b
return result
end
=======
local function add(a, b) return a + b end
>>>>>>> REPLACE
]]
        local ok, modified_code, changes_count = patcher.apply_patch(source_code, patch)
        
        assert.is_true(ok)
        assert.are.equal(1, changes_count)
        assert.truthy(modified_code:match("local function add%(a, b%) return a %+ b end"))
    end)

    it("3. [SAFETY] Should REJECT ambiguous matches (Circuit Breaker)", function()
        -- Пытаемся заменить кусок кода, который повторяется дважды
        local patch = [[
<<<<<<< SEARCH
    local result = a + b
    return result
=======
    return a + b
>>>>>>> REPLACE
]]
        -- Модифицируем source_code так, чтобы блок поиска не был уникальным
        local ambiguous_source = source_code:gsub("a %- b", "a %+ b") 
        
        local ok, err_msg = patcher.apply_patch(ambiguous_source, patch)
        
        assert.is_false(ok)
        assert.truthy(err_msg)
        assert.truthy(err_msg:match("AMBIGUOUS MATCH"), "Safety lock failed! Patcher allowed an ambiguous edit.")
    end)

    it("4. [MULTI-BLOCK] Should process multiple patches in a single payload", function()
        local patch = [[
<<<<<<< SEARCH
    local result = a + b
    return result
=======
    return a + b
>>>>>>> REPLACE

Some LLM commentary here...

<<<<<<< SEARCH
    local result = a - b
    return result
=======
    return a - b
>>>>>>> REPLACE
]]
        local ok, modified_code, changes_count = patcher.apply_patch(source_code, patch)
        
        assert.is_true(ok)
        assert.are.equal(2, changes_count)
        assert.falsy(modified_code:match("local result =")) -- Убеждаемся, что старые строки удалены
    end)

    it("5. [FAILSAFE] Should fail gracefully on malformed patch boundaries", function()
        local patch = [[
<<<<<<< SEARCH
    return result
=======
    return 0
-- Missing REPLACE tag!
]]
        local ok, err_msg = patcher.apply_patch(source_code, patch)
        
        assert.is_false(ok)
        assert.truthy(err_msg:match("No valid SEARCH/REPLACE blocks found"))
    end)

    it("7. [ZERO-OP] Should trigger circuit breaker on identical search/replace blocks", function()
        local patch = [[
<<<<<<< SEARCH
    local result = a + b
    return result
=======
    local result = a + b
    return result
>>>>>>> REPLACE
]]
        local ok, err_msg = patcher.apply_patch(source_code, patch)
        assert.is_false(ok)
        assert.truthy(err_msg:match("EXACTLY identical"))
    end)

    it("6. [EDGE CASE] Should handle CRLF (\\r\\n) vs LF (\\n) line endings seamlessly", function()
        local crlf_source = source_code:gsub("\n", "\r\n")
        local patch = [[
<<<<<<< SEARCH
local function calculate_sum(a, b)
=======
local function sum(a, b)
>>>>>>> REPLACE
]]
        local ok, modified_code, changes_count = patcher.apply_patch(crlf_source, patch)
        
        assert.is_true(ok)
        assert.are.equal(1, changes_count)
        assert.truthy(modified_code:match("local function sum"))
    end)
end)
