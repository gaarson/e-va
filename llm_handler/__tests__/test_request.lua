describe("LLM Request Handler", function()
    local llm_handler = require("llm_handler")

    -- Helper: create a minimal mock profile
    local function make_profile(overrides)
        overrides = overrides or {}
        return {
            url = overrides.url or "http://localhost:8000/v1/chat/completions",
            model = overrides.model or "test-model",
            token = overrides.token or "test-token",
            provider = overrides.provider or "openai",
            params = overrides.params or {}
        }
    end

    -- ========================================================================
    -- TEST 1: Module exports
    -- ========================================================================
    describe("Module exports", function()
        it("should have send_request function", function()
            assert.is_true(type(llm_handler.send_request) == "function")
        end)
        it("should have extract_content function", function()
            assert.is_true(type(llm_handler.extract_content) == "function")
        end)
        it("should have cqueues module", function()
            assert.is_true(type(llm_handler.cqueues) == "table")
        end)
        it("should have async_ll_call function", function()
            assert.is_true(type(llm_handler.async_ll_call) == "function")
        end)
    end)

    -- ========================================================================
    -- TEST 2: Invalid profile handling
    -- ========================================================================
    describe("Invalid profile handling", function()
        it("should return error for nil profile", function()
            local result, err = llm_handler.send_request(nil, {})
            assert.is_nil(result)
            assert.equals("Invalid Profile", err)
        end)
        it("should return error for profile without url", function()
            local profile = { model = "test-model" }
            local result, err = llm_handler.send_request(profile, {})
            assert.is_nil(result)
            assert.equals("Invalid Profile", err)
        end)
        it("should return error for profile with empty url", function()
            local profile = { url = "", model = "test-model" }
            local result, err = llm_handler.send_request(profile, {})
            assert.is_nil(result)
            assert.equals("Invalid Profile", err)
        end)
    end)

    -- ========================================================================
    -- TEST 3: extract_content with mock responses
    -- ========================================================================
    describe("extract_content", function()
        it("should extract content from standard OpenAI response", function()
            local mock_response = {
                choices = {
                    {
                        message = {
                            role = "assistant",
                            content = "Hello, world!"
                        }
                    }
                }
            }
            local content = llm_handler.extract_content(mock_response, "openai")
            assert.equals("Hello, world!", content)
        end)
        it("should extract content with reasoning", function()
            local mock_response = {
                choices = {
                    {
                        message = {
                            role = "assistant",
                            content = "Final answer",
                            reasoning_content = "Let me think..."
                        }
                    }
                }
            }
            local content = llm_handler.extract_content(mock_response, "openai")
            assert.truthy(content:match("Let me think%."))
            assert.truthy(content:match("Final answer"))
        end)
        it("should return nil for malformed response", function()
            local mock_response = { invalid = "data" }
            local content = llm_handler.extract_content(mock_response, "openai")
            assert.is_nil(content)
        end)
        it("should return nil for empty choices", function()
            local mock_response = { choices = {} }
            local content = llm_handler.extract_content(mock_response, "openai")
            assert.is_nil(content)
        end)
        it("should default to openai provider", function()
            local mock_response = {
                choices = {
                    {
                        message = {
                            role = "assistant",
                            content = "Test"
                        }
                    }
                }
            }
            local content = llm_handler.extract_content(mock_response)
            assert.equals("Test", content)
        end)
    end)
end)