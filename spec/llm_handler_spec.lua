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

    it("flattens profile parameters into the payload root for TabbyAPI", function()
        local captured_payload = nil
        -- Перехватываем вызов json.encode, чтобы изучить сформированную таблицу до сериализации
        json.encode = function(self, tbl)
            captured_payload = tbl
            return "{}"
        end

        local test_profile = {
            url = "http://localhost",
            model = "Qwen-Test",
            params = {
                temperature = 0.5,
                min_p = 0.05,
                smoothing_factor = 0.2,
                temperature_last = true
            }
        }

        local mock_req = {
            headers = { upsert = function() end },
            set_body = function() end,
            go = function() return { get = function() return "200" end }, { get_body_as_string = function() return "{}" end } end
        }
        http_request.new_from_uri = function() return mock_req end

        llm_handler.send_request(test_profile, { { role = "user", content = "test" } })

        assert.is_table(captured_payload)
        -- КРИТИЧЕСКАЯ ПРОВЕРКА: параметры должны быть в корне, а не внутри captured_payload.params
        assert.are.equal("Qwen-Test", captured_payload.model)
        assert.are.equal(0.5, captured_payload.temperature)
        assert.are.equal(0.05, captured_payload.min_p)
        assert.are.equal(0.2, captured_payload.smoothing_factor)
        assert.is_true(captured_payload.temperature_last)
        assert.is_false(captured_payload.stream) -- Проверка дефолтного fallback'а
    end)

    it("applies dynamic override_params directly to the payload root", function()
        local captured_payload = nil
        json.encode = function(self, tbl)
            captured_payload = tbl
            return "{}"
        end

        local test_profile = {
            url = "http://localhost",
            model = "Qwen-Test",
            params = { temperature = 0.1, min_p = 0.05 }
        }

        local mock_req = {
            headers = { upsert = function() end },
            set_body = function() end,
            go = function() return { get = function() return "200" end }, { get_body_as_string = function() return "{}" end } end
        }
        http_request.new_from_uri = function() return mock_req end

        -- Имитируем запрос с оверрайдом (например, для circuit breaker'а)
        llm_handler.send_request(test_profile, {}, { 
            override_params = { temperature = 0.9, top_k = 50 } 
        })

        assert.is_table(captured_payload)
        assert.are.equal(0.9, captured_payload.temperature) -- Должен перезаписать 0.1
        assert.are.equal(0.05, captured_payload.min_p)      -- Должен остаться из профиля
        assert.are.equal(50, captured_payload.top_k)        -- Должен добавиться новый
    end)

end)
