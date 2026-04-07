local providers = require("llm_providers")

describe("LLM Providers (Adapter Pattern)", function()
    it("should fallback to openai if provider is unknown", function()
        local p = providers.get("unknown_garbage")
        assert.is_table(p)
        assert.is_function(p.build_payload)
    end)

    describe("OpenAI Provider", function()
        local p = providers.get("openai")

        it("should format sync response correctly", function()
            local mock_res = {
                choices = {
                    { message = { content = "Hello world", reasoning_content = "Thinking..." } }
                }
            }
            local content = p.extract_sync(mock_res)
            assert.truthy(content:match("<think>\nThinking...\n</think>"))
            assert.truthy(content:match("Hello world"))
        end)

        it("should handle malformed sync responses safely", function()
            assert.is_nil(p.extract_sync({}))
            assert.is_nil(p.extract_sync({ choices = {} }))
        end)
    end)

    describe("Anthropic Provider", function()
        local p = providers.get("anthropic")

        it("should extract system prompt to root level", function()
            local messages = {
                { role = "system", content = "You are an AI." },
                { role = "user", content = "Hi" }
            }
            local payload = p.build_payload({ model = "claude-3", params = {} }, messages)
            
            assert.are.equal("You are an AI.", payload.system)
            assert.are.equal(1, #payload.messages)
            assert.are.equal("Hi", payload.messages[1].content)
        end)
    end)
end)
