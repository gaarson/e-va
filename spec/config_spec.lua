local config_module = require("config")
local os = require("os")

describe("Configuration Subsystem (Pipeline & Agents)", function()
    before_each(function()
        stub(os, "getenv").returns("/opt/mock_root")
    end)

    after_each(function()
        os.getenv:revert()
    end)

    it("should load base system paths", function()
        local config = config_module.get()
        assert.is_table(config)
        assert.are.equal("/opt/mock_root", config.PROJECT_ROOT)
    end)

    it("should establish deterministic limits", function()
        local config = config_module.get()
        assert.are.equal(100000, config.LIMITS.MAX_CONTEXT)
        assert.are.equal(0.8, config.LIMITS.MEMORY_RATIO)
    end)

    it("should correctly configure the ARCHITECT agent", function()
        local config = config_module.get()
        local arch = config.AGENTS.ARCHITECT

        assert.is_table(arch)
        assert.are.equal("ARCHITECT", arch.name)
        assert.are.equal(0.1, arch.params.temperature)
        assert.is_true(arch.params.token_healing)
        -- Verify allowed tools
        assert.truthy(require("utils").table_contains(arch.allowed_tools, "delegate_plan"))
        assert.truthy(require("utils").table_contains(arch.allowed_tools, "ask_user"))
    end)

    it("should correctly configure the CODER agent", function()
        local config = config_module.get()
        local coder = config.AGENTS.CODER

        assert.is_table(coder)
        -- Обновленный assertion: ожидаем температуру 0.35 из профиля ENGINEERING
        assert.are.equal(0.35, coder.params.temperature)
        assert.truthy(require("utils").table_contains(coder.allowed_tools, "patch"))
    end)

    it("should assign deep-merged ANALYTICAL profile to ARCHITECT", function()
        local config = config_module.get()
        local params = config.AGENTS.ARCHITECT.params

        -- Проверяем наличие базовых параметров
        assert.is_true(params.stream)
        assert.is_table(params.stop)

        -- Проверяем наличие специфичных параметров TabbyAPI / ExLlamaV2
        assert.are.equal(0.1, params.temperature)
        assert.are.equal(1.0, params.top_p)
        assert.are.equal(0.05, params.min_p)
        assert.is_true(params.temperature_last)
        assert.are.equal(0.1, params.smoothing_factor)
    end)

    it("should assign deep-merged ENGINEERING profile to CODER", function()
        local config = config_module.get()
        local params = config.AGENTS.CODER.params

        -- Проверяем отличия инженерного профиля
        assert.are.equal(0.35, params.temperature)
        assert.are.equal(0.1, params.min_p)
        assert.are.equal(0.2, params.smoothing_factor)
        assert.are.equal(0.1, params.presence_penalty)
    end)


    it("should have interactive REVIEW_AND_CHAT stage in PIPELINE", function()
        local config = config_module.get()
        local has_interactive = false
        for _, stage in ipairs(config.PIPELINE) do
            if stage.mode == "interactive" and stage.stage == "REVIEW_AND_CHAT" then
                has_interactive = true
            end
        end
        assert.is_true(has_interactive, "Pipeline should contain an interactive stage")
    end)
end)

-- Helper function for the tests
require("utils").table_contains = function(tbl, val)
    for _, v in ipairs(tbl) do if v == val then return true end end
    return false
end
