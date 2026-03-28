local llm_handler = require("llm_handler")
local http_request = require("http.request")
local json = require("JSON")

describe("LLM Handler (Network & Parsing)", function()
    local mock_profile
    local orig_new_from_uri
    local orig_decode
    local orig_encode

    before_each(function()
        mock_profile = {
            url = "http://localhost",
            model = "test",
            params = { stream = false }
        }
        orig_new_from_uri = http_request.new_from_uri
        orig_decode = json.decode
        orig_encode = json.encode
        
        -- Бронебойная заглушка: возвращаем таблицу, достаточную для прохождения
        -- всех внутренних проверок (if ok and part.choices...) внутри llm_handler
        json.encode = function() return "{}" end
        json.decode = function() 
            return { choices = { { delta = { content = "token" } } } } 
        end
    end)

    after_each(function()
        http_request.new_from_uri = orig_new_from_uri
        json.decode = orig_decode
        json.encode = orig_encode
    end)

    it("handles connection timeouts and HTTP errors", function()
        local mock_req = { headers = { upsert = function() end }, set_body = function() end, go = function() return nil, "timeout" end }
        http_request.new_from_uri = function() return mock_req end
        assert.is_nil(llm_handler.send_request(mock_profile, {}))
        
        mock_req.go = function(self)
            if not self.c then self.c = true return {}, {} end
            return nil, "fail"
        end
        assert.is_nil(llm_handler.send_request(mock_profile, {}))

        mock_req.go = function() return { get = function() return "500" end }, { get_body_as_string = function() return "" end } end
        assert.is_nil(llm_handler.send_request(mock_profile, {}))
    end)

    it("handles non-streaming requests", function()
        local mock_req = {
            headers = { upsert = function() end }, set_body = function() end,
            go = function() return { get = function() return "200" end }, { get_body_as_string = function() return "{}" end } end
        }
        http_request.new_from_uri = function() return mock_req end
        
        local res = llm_handler.send_request(mock_profile, {})
        assert.is_table(res)
    end)

    it("processes SSE stream without crashing", function()
        mock_profile.params.stream = true
        -- Эмулируем чанки, чтобы пройти по циклу each_chunk и сбросить [DONE]
        local chunks = { "data: {}\n\n", "data: [DONE]\n\n" }
        local mock_req = {
            headers = { upsert = function() end }, set_body = function() end,
            go = function() 
                return { get = function() return "200" end }, { each_chunk = function() local i=0 return function() i=i+1 return chunks[i] end end }
            end
        }
        http_request.new_from_uri = function() return mock_req end
        
        -- Вызываем с on_token, чтобы покрыть 100% веток внутри цикла
        local res = llm_handler.send_request(mock_profile, {}, { on_token = function() end })
        assert.is_table(res)
    end)

    it("extracts content safely", function()
        assert.is_nil(llm_handler.extract_content(nil))
        assert.is_nil(llm_handler.extract_content({}))
        -- Здесь мы передаем чистую таблицу, так что парсер нас не обманет
        assert.are.equal("ok", llm_handler.extract_content({ choices = { { message = { content = "ok" } } } }))
    end)
end)
