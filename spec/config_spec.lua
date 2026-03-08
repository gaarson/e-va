local config_module = require("config")
local os = require("os")

describe("Configuration Subsystem", function()
    before_each(function()
        -- Изолируем обращение к переменным окружения ОС
        stub(os, "getenv").returns("/opt/mock_root")
    end)

    after_each(function()
        os.getenv:revert()
    end)

    it("should load base system paths and environment overrides", function()
        local config = config_module.get()
        assert.is_table(config)
        assert.are.equal("/opt/mock_root", config.PROJECT_ROOT)
    end)

    it("should establish deterministic limits and memory boundaries", function()
        local config = config_module.get()
        assert.is_table(config.LIMITS)
        assert.are.equal(100000, config.LIMITS.MAX_CONTEXT)
        assert.are.equal(0.8, config.LIMITS.MEMORY_RATIO)
    end)

    it("should accurately merge BASE and SPECIFIC LLM hyperparameters", function()
        local config = config_module.get()
        
        -- Проверка профиля BRAIN (MAIN)
        assert.is_table(config.LLM_MAIN)
        assert.is_table(config.LLM_MAIN.params)
        
        -- Проверяем, что базовые параметры (stream) успешно смерджились
        assert.is_true(config.LLM_MAIN.params.stream)
        
        -- Проверяем специфичные параметры профиля
        assert.are.equal(16384, config.LLM_MAIN.params.max_tokens)
        assert.are.equal(0.1, config.LLM_MAIN.params.temperature)
        assert.is_true(config.LLM_MAIN.params.token_healing)
        
        -- Проверка профиля SCOUT
        assert.is_table(config.LLM_SCOUT)
        assert.are.equal(0.2, config.LLM_SCOUT.params.temperature)
    end)
end)
