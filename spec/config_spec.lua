local config_module = require("config")
local os = require("os")

describe("Configuration Subsystem (Pipeline & Agents Schema Validation)", function()
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

    it("should establish deterministic limits schema (type checking)", function()
        local config = config_module.get()
        
        assert.is_table(config.LIMITS, "LIMITS must be a table")
        assert.is_number(config.LIMITS.MAX_CONTEXT, "MAX_CONTEXT must be a number")
        assert.is_true(config.LIMITS.MAX_CONTEXT > 0, "MAX_CONTEXT must be greater than 0")
        
        assert.is_number(config.LIMITS.MEMORY_RATIO, "MEMORY_RATIO must be a number")
        assert.is_true(config.LIMITS.MEMORY_RATIO > 0 and config.LIMITS.MEMORY_RATIO <= 1, "MEMORY_RATIO must be between 0 and 1")
    end)

    it("should dynamically validate the schema of ALL configured agents", function()
        local config = config_module.get()
        
        assert.is_table(config.AGENTS, "AGENTS must be a table")
        
        local agent_count = 0
        for agent_key, agent_data in pairs(config.AGENTS) do
            agent_count = agent_count + 1
            
            assert.is_string(agent_data.name, "Agent name must be a string for key: " .. agent_key)
            assert.is_string(agent_data.url, "Agent url must be a string for key: " .. agent_key)
            assert.is_string(agent_data.model, "Agent model must be a string for key: " .. agent_key)
            assert.is_table(agent_data.allowed_tools, "Agent allowed_tools must be a table for key: " .. agent_key)
            
            local params = agent_data.params
            assert.is_table(params, "Agent params must be a table for key: " .. agent_key)
            
            if params.stream ~= nil then assert.is_boolean(params.stream, "params.stream must be a boolean in " .. agent_key) end
            if params.stop ~= nil then assert.is_table(params.stop, "params.stop must be a table in " .. agent_key) end
            if params.max_tokens ~= nil then assert.is_number(params.max_tokens, "params.max_tokens must be a number in " .. agent_key) end
            if params.temperature ~= nil then assert.is_number(params.temperature, "params.temperature must be a number in " .. agent_key) end
            if params.top_p ~= nil then assert.is_number(params.top_p, "params.top_p must be a number in " .. agent_key) end
            if params.min_p ~= nil then assert.is_number(params.min_p, "params.min_p must be a number in " .. agent_key) end
            if params.presence_penalty ~= nil then assert.is_number(params.presence_penalty, "params.presence_penalty must be a number in " .. agent_key) end
            if params.repetition_penalty ~= nil then assert.is_number(params.repetition_penalty, "params.repetition_penalty must be a number in " .. agent_key) end
            if params.smoothing_factor ~= nil then assert.is_number(params.smoothing_factor, "params.smoothing_factor must be a number in " .. agent_key) end
            if params.temperature_last ~= nil then assert.is_boolean(params.temperature_last, "params.temperature_last must be a boolean in " .. agent_key) end
            if params.token_healing ~= nil then assert.is_boolean(params.token_healing, "params.token_healing must be a boolean in " .. agent_key) end
        end
        
        assert.is_true(agent_count > 0, "At least one agent must be configured in config.AGENTS")
    end)

    it("should dynamically validate the schema of the PIPELINE", function()
        local config = config_module.get()
        assert.is_table(config.PIPELINE, "PIPELINE must be a table")
        
        for i, stage in ipairs(config.PIPELINE) do
            assert.is_string(stage.stage, "Pipeline stage name must be a string at index " .. i)
            assert.is_string(stage.mode, "Pipeline mode must be a string at index " .. i)
            
            local valid_modes = { sequential = true, interactive = true, parallel = true }
            assert.is_true(valid_modes[stage.mode] == true, "Invalid pipeline mode: " .. stage.mode .. " at index " .. i)
            
            assert.truthy(type(stage.agents) == "table" or type(stage.agents) == "string", "Pipeline agents must be a table or string at index " .. i)
        end
    end)

    it("should load pipeline settings and task queue schema", function()
        local config = config_module.get()
        assert.is_table(config.PIPELINE_SETTINGS)
        assert.is_number(config.PIPELINE_SETTINGS.MAX_TURNS)
        assert.is_boolean(config.PIPELINE_SETTINGS.ABORT_ON_FATAL)
        
        assert.is_table(config.TASKS)
    end)

    it('should include PICTURES_DIR configuration option', function()
        local config = config_module.get()
        assert.is_nil(config.PICTURES_DIR, 'PICTURES_DIR should be nil by default')
        assert.is_true(config.CREATE_BACKUPS ~= nil, 'CREATE_BACKUPS should still exist')
    end)

    it("should export AGENT_DEFAULTS with url, model, is_reasoning, and params", function()
        local config = config_module.get()
        assert.is_table(config.AGENT_DEFAULTS, "AGENT_DEFAULTS must be a table")
        assert.is_string(config.AGENT_DEFAULTS.url, "AGENT_DEFAULTS.url must be a string")
        assert.is_string(config.AGENT_DEFAULTS.model, "AGENT_DEFAULTS.model must be a string")
        assert.is_boolean(config.AGENT_DEFAULTS.is_reasoning, "AGENT_DEFAULTS.is_reasoning must be a boolean")
        assert.is_table(config.AGENT_DEFAULTS.params, "AGENT_DEFAULTS.params must be a table")
    end)

    it("should allow minimal side-project agents to inherit defaults via apply_agent_defaults", function()
        local utils = require("utils")
        local config = config_module.get()

        config.AGENTS.MINIMAL_AGENT = {
            name = "MINIMAL_AGENT",
            prompt_file = "prompts/minimal.md",
            allowed_tools = { "read_file", "task_complete" }
        }

        config = utils.apply_agent_defaults(config)

        assert.are.equal(config.AGENT_DEFAULTS.url, config.AGENTS.MINIMAL_AGENT.url, "Minimal agent should inherit url")
        assert.are.equal(config.AGENT_DEFAULTS.model, config.AGENTS.MINIMAL_AGENT.model, "Minimal agent should inherit model")
        assert.are.equal(config.AGENT_DEFAULTS.is_reasoning, config.AGENTS.MINIMAL_AGENT.is_reasoning, "Minimal agent should inherit is_reasoning")
        assert.is_table(config.AGENTS.MINIMAL_AGENT.params, "Minimal agent should inherit params")
        assert.are.equal(true, config.AGENTS.MINIMAL_AGENT.params.stream, "Inherited params should include stream=true")

        config.AGENTS.MINIMAL_AGENT = nil
    end)

    it("should NOT overwrite explicit agent fields with defaults (no regression)", function()
        local utils = require("utils")
        local config = config_module.get()

        config.AGENTS.EXPLICIT_AGENT = {
            name = "EXPLICIT_AGENT",
            url = "http://custom-server:9999/v1/chat/completions",
            model = "custom-model-v2",
            is_reasoning = true,
            params = { temperature = 0.9, max_tokens = 4096 },
            prompt_file = "prompts/explicit.md",
            allowed_tools = { "shell", "task_complete" }
        }

        config = utils.apply_agent_defaults(config)

        assert.are.equal("http://custom-server:9999/v1/chat/completions", config.AGENTS.EXPLICIT_AGENT.url, "Explicit url should NOT be overwritten")
        assert.are.equal("custom-model-v2", config.AGENTS.EXPLICIT_AGENT.model, "Explicit model should NOT be overwritten")
        assert.are.equal(true, config.AGENTS.EXPLICIT_AGENT.is_reasoning, "Explicit is_reasoning should NOT be overwritten")
        assert.are.equal(0.9, config.AGENTS.EXPLICIT_AGENT.params.temperature, "Explicit params.temperature should NOT be overwritten")
        assert.are.equal(4096, config.AGENTS.EXPLICIT_AGENT.params.max_tokens, "Explicit params.max_tokens should NOT be overwritten")

        config.AGENTS.EXPLICIT_AGENT = nil
    end)

    it("should provide a config object compatible with tools/init (has MCP_SERVERS)", function()
        local config = config_module.get()
        assert.is_table(config.MCP_SERVERS, "Config must have MCP_SERVERS table for tools/init compatibility")
    end)

    it("should handle plain table config in tools/init without crashing", function()
        -- Save original package.loaded state
        local original_config_module = package.loaded["config"]
        local original_tools_init = package.loaded["tools"]
        
        -- Clear tools cache to force reload during test if necessary
        package.loaded["tools"] = nil
        
        -- Mock a plain table config module
        local plain_table_config = {
            PROJECT_ROOT = "/tmp/test_plain",
            MCP_SERVERS = {},
            LIMITS = { MAX_CONTEXT = 1000 }
        }
        
        -- Inject the mock into package.loaded
        package.loaded["config"] = plain_table_config
        
        -- Load tools/init.lua manually to test the init function behavior
        local tools_mod = require("tools")
        
        -- Call init with nil to trigger the fallback logic
        local ok, err = pcall(tools_mod.init, nil)
        
        -- Revert mocks
        package.loaded["config"] = original_config_module
        package.loaded["tools"] = original_tools_init
        
        assert.is_true(ok, "tools.init should not crash when config is a plain table. Error: " .. tostring(err))
    end)
end)

require("utils").table_contains = function(tbl, val)
    for _, v in ipairs(tbl) do if v == val then return true end end
    return false
end