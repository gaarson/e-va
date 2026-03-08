local llm_handler = require("llm_handler")
local http_request = require("http.request")

describe("LLM Handler (Network & Parsing)", function()
    local mock_profile
    
    before_each(function()
        mock_profile = {
            url = "http://localhost:5000/v1/chat/completions",
            model = "test-model",
            params = { stream = false }
        }
    end)

    it("should gracefully handle connection timeouts", function()
        -- Перехватываем http.new_from_uri для симуляции сети
        local mock_req = {
            headers = { upsert = function() end },
            set_body = function() end,
            go = function() return nil, "timeout" end
        }
        stub(http_request, "new_from_uri").returns(mock_req)

        local response, err = llm_handler.send_request(mock_profile, {})
        
        assert.is_nil(response)
        assert.truthy(err:match("timeout"))
        
        http_request.new_from_uri:revert()
    end)

    it("should correctly extract content from a valid JSON response", function()
        local mock_data = {
            choices = {
                { message = { role = "assistant", content = "Code generated." } }
            }
        }
        local content = llm_handler.extract_content(mock_data)
        assert.are.equal("Code generated.", content)
    end)

    it("should return nil if choices array is missing", function()
        local bad_data = { choices = {} }
        assert.is_nil(llm_handler.extract_content(bad_data))
    end)
end)
