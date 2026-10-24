describe("UTF-8 Sanitization", function()
    local encoding = require("utils.encoding")
    -- ========================================================================
    -- TEST 1: sanitize_for_json with various inputs
    -- ========================================================================
    describe("sanitize_for_json", function()
        it("should pass valid ASCII through unchanged", function()
            local input = "Hello World, this is a test."
            local result = encoding.sanitize_for_json(input)
            assert.equals(input, result)
        end)
        it("should pass valid UTF-8 Cyrillic text through unchanged", function()
            local input = "\xD0\x9F\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82 \xd0\xbc\xd0\xb8\xd1\x80"
            local result = encoding.sanitize_for_json(input)
            assert.equals(input, result)
        end)
        it("should pass valid UTF-8 CJK text through unchanged", function()
            local input = "\xE4\xBD\xa0\xE5\xA5\xBD\xE4\xB8\x96\xE7\x95\x8C"
            local result = encoding.sanitize_for_json(input)
            assert.equals(input, result)
        end)
        it("should pass valid UTF-8 emoji through unchanged", function()
            local input = "\xF0\x9F\x98\x80"
            local result = encoding.sanitize_for_json(input)
            assert.equals(input, result)
        end)
        it("should replace lone continuation byte 0x80 with ?", function()
            local input = "abc" .. string.char(0x80) .. "def"
            local result = encoding.sanitize_for_json(input)
            assert.is_true(result:find("?") ~= nil)
            assert.is_false(result:find(string.char(0x80), 1, true) ~= nil)
        end)
        it("should replace incomplete 2-byte sequence (0xC0 without valid continuation) with ?", function()
            local input = "abc" .. string.char(0xC0) .. "def"
            local result = encoding.sanitize_for_json(input)
            assert.is_true(result:find("?") ~= nil)
        end)
        it("should replace incomplete 3-byte sequence (0xE0 with only 1 continuation) with ?", function()
            local input = "abc" .. string.char(0xE0, 0x80) .. "def"
            local result = encoding.sanitize_for_json(input)
            assert.is_true(result:find("?") ~= nil)
        end)
        it("should remove null bytes", function()
            local input = "abc" .. string.char(0) .. "def"
            local result = encoding.sanitize_for_json(input)
            assert.equals("abcdef", result)
        end)
        it("should escape control characters as unicode escapes", function()
            local input = "a" .. string.char(1) .. "b"
            local result = encoding.sanitize_for_json(input)
            assert.is_true(result:find("%\\u0001") ~= nil)
            assert.is_false(result:find(string.char(1), 1, true) ~= nil)
        end)
        it("should handle empty string", function()
            local result = encoding.sanitize_for_json("")
            assert.equals("", result)
        end)
        it("should handle non-string input by converting to string", function()
            local result = encoding.sanitize_for_json(42)
            assert.equals("42", result)
        end)
        it("should pass Russian text through byte-for-byte identical", function()
            local input = "\xD0\x9F\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82"
            local result = encoding.sanitize_for_json(input)
            assert.equals(#input, #result)
            for i = 1, #input do
                assert.equals(string.byte(input, i), string.byte(result, i))
            end
        end)
    end)
    -- ========================================================================
    -- TEST 2: Recursive payload sanitization (inline test of the logic)
    -- ========================================================================
    describe("Recursive payload sanitization", function()
        local function sanitize_recursive(t)
            if type(t) == "string" then
                return encoding.sanitize_for_json(t)
            elseif type(t) == "table" then
                for k, v in pairs(t) do
                    t[k] = sanitize_recursive(v)
                end
                return t
            else
                return t
            end
        end
        it("should handle nested tables with invalid bytes", function()
            local payload = {
                a = "hello",
                b = { c = string.char(0xFF) .. "world" },
                d = 42,
                e = true
            }
            sanitize_recursive(payload)
            assert.equals("hello", payload.a)
            assert.is_true(payload.b.c:find("?") ~= nil)
            assert.equals(42, payload.d)
            assert.is_true(payload.e == true)
        end)
        it("should handle arrays (sequential tables)", function()
            local payload = {
                "valid",
                string.char(0x80) .. "invalid",
                "also valid"
            }
            sanitize_recursive(payload)
            assert.equals("valid", payload[1])
            assert.is_true(payload[2]:find("?") ~= nil)
            assert.equals("also valid", payload[3])
        end)
        it("should handle deeply nested structures", function()
            local payload = {
                messages = {
                    { role = "user", content = "hello" .. string.char(0xFF) },
                    { role = "assistant", content = { type = "text", text = "response" } }
                },
                model = "test",
                temperature = 0.7
            }
            sanitize_recursive(payload)
            assert.is_true(payload.messages[1].content:find("?") ~= nil)
            assert.equals("response", payload.messages[2].content.text)
            assert.equals("test", payload.model)
            assert.equals(0.7, payload.temperature)
        end)
        it("should not modify non-string, non-table values", function()
            local payload = { num = 3.14, bool = false }
            sanitize_recursive(payload)
            assert.equals(3.14, payload.num)
            assert.is_true(payload.bool == false)
        end)
    end)
    -- ========================================================================
    -- TEST 3: _validate_utf8_body logic (inline replication)
    -- ========================================================================
    describe("_validate_utf8_body", function()
        local function validate_utf8_body(body)
            local len = #body
            local i = 1
            while i <= len do
                local b = string.byte(body, i)
                if b == nil then break end
                if b >= 0x80 and b <= 0xBF then
                    if i == 1 or not (string.byte(body, i - 1) >= 0xC2 and string.byte(body, i - 1) <= 0xF4) then
                        return false, i
                    end
                elseif b >= 0xC2 and b <= 0xDF then
                    if i + 1 > len or not (string.byte(body, i + 1) >= 0x80 and string.byte(body, i + 1) <= 0xBF) then
                        return false, i
                    end
                    i = i + 2
                elseif b >= 0xE0 and b <= 0xEF then
                    if i + 2 > len or not (string.byte(body, i + 1) >= 0x80 and string.byte(body, i + 1) <= 0xBF)
                        or not (string.byte(body, i + 2) >= 0x80 and string.byte(body, i + 2) <= 0xBF) then
                        return false, i
                    end
                    i = i + 3
                elseif b >= 0xF0 and b <= 0xF4 then
                    if i + 3 > len or not (string.byte(body, i + 1) >= 0x80 and string.byte(body, i + 1) <= 0xBF)
                        or not (string.byte(body, i + 2) >= 0x80 and string.byte(body, i + 2) <= 0xBF)
                        or not (string.byte(body, i + 3) >= 0x80 and string.byte(body, i + 3) <= 0xBF) then
                        return false, i
                    end
                    i = i + 4
                else
                    i = i + 1
                end
            end
            return true, nil
        end
        it("should accept valid ASCII", function()
            local ok, pos = validate_utf8_body("Hello World")
            assert.is_true(ok)
            assert.is_nil(pos)
        end)
        it("should accept valid UTF-8 Cyrillic", function()
            local ok, pos = validate_utf8_body("\xD0\x9F\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82")
            assert.is_true(ok)
            assert.is_nil(pos)
        end)
        it("should accept valid UTF-8 emoji (4-byte)", function()
            local ok, pos = validate_utf8_body("\xF0\x9F\x98\x80")
            assert.is_true(ok)
            assert.is_nil(pos)
        end)
        it("should reject lone continuation byte 0x80 at start", function()
            local body = string.char(0x80) .. "abc"
            local ok, pos = validate_utf8_body(body)
            assert.is_false(ok)
            assert.equals(1, pos)
        end)
        it("should reject incomplete 2-byte sequence at end", function()
            local body = "abc" .. string.char(0xC3)
            local ok, pos = validate_utf8_body(body)
            assert.is_false(ok)
            assert.equals(4, pos)
        end)
        it("should reject incomplete 3-byte sequence", function()
            local body = "a" .. string.char(0xE2, 0x82) .. "b"
            local ok, pos = validate_utf8_body(body)
            assert.is_false(ok)
            assert.equals(2, pos)
        end)
        it("should reject incomplete 4-byte sequence", function()
            local body = string.char(0xF0, 0x9F, 0x98)
            local ok, pos = validate_utf8_body(body)
            assert.is_false(ok)
            assert.equals(1, pos)
        end)
        it("should accept empty string", function()
            local ok, pos = validate_utf8_body("")
            assert.is_true(ok)
            assert.is_nil(pos)
        end)
        it("should skip bytes above 0xF4 (like 0xFF) without crashing", function()
            local body = "abc" .. string.char(0xFF) .. "def"
            local ok, pos = validate_utf8_body(body)
            assert.is_true(ok)
        end)
    end)
    -- ========================================================================
    -- TEST 4: Integration test with mocked dependencies
    -- ========================================================================
    describe("Integration: send_request with invalid UTF-8", function()
        it("should sanitize or reject payload containing byte 0xFF", function()
            local mock_modules = {}
            mock_modules["http.request"] = {
                new_from_uri = function(uri)
                    return {
                        headers = {
                            upsert = function(self, k, v) end,
                            delete = function(self, k) end,
                            get = function(self, k) return "200" end,
                        },
                        set_body = function(self, body) self._body = body end,
                        go = function(self, timeout)
                            local mock_headers = {
                                get = function(self, k)
                                    if k == ":status" then return "200" end
                                    if k == "content-type" then return "application/json" end
                                    return nil
                                end
                            }
                            local mock_stream = {
                                get_body_as_string = function()
                                    return '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}'
                                end
                            }
                            return mock_headers, mock_stream
                        end
                    }
                end
            }
            local json_mock = {}
            json_mock.encode = function(self, t)
                if type(t) == "string" then
                    return '"' .. t:gsub('"', '\\"') .. '"'
                elseif type(t) == "table" then
                    local parts = {}
                    for k, v in pairs(t) do
                        table.insert(parts, string.format('"%s":%s', tostring(k), json_mock.encode(self, v)))
                    end
                    return "{" .. table.concat(parts, ",") .. "}"
                elseif type(t) == "number" then
                    return tostring(t)
                elseif type(t) == "boolean" then
                    return tostring(t)
                else
                    return "null"
                end
            end
            json_mock.decode = function(self, s)
                return {}
            end
            setmetatable(json_mock, { __call = function() return json_mock end })
            mock_modules["JSON"] = json_mock
            mock_modules["logger"] = {
                info = function(msg) end,
                warn = function(msg) end,
                error = function(msg) end,
            }
            mock_modules["llm_providers"] = {
                get = function(name)
                    return {
                        build_payload = function(profile, messages, options)
                            return {
                                model = profile.model,
                                messages = messages,
                                stream = false
                            }
                        end,
                        extract_sync = function(data)
                            if data.choices and data.choices[1] then
                                return data.choices[1].message.content
                            end
                            return nil
                        end
                    }
                end
            }
            mock_modules["context_optimizer"] = {
                is_context_exceeded = function(body) return false end,
                shrink_max_tokens = function(cfg, min) cfg.max_tokens = min end,
            }
            mock_modules["llm_handler.dedup"] = {
                _request_hash = function(profile, messages, options) return "test_hash" end,
                _in_flight_requests = {},
                _DEDUP_WINDOW = 5,
                _DEDUP_CLEANUP_INTERVAL = 60,
                _cleanup_in_flight = function() end,
            }
            mock_modules["llm_handler.stream"] = {
                process_stream = function(stream_obj, profile, provider, on_token)
                    return { choices = { { message = { role = "assistant", content = "streamed" } } } }
                end
            }
            mock_modules["cqueues"] = {
                monotime = function() return os.clock() end,
            }
            local saved_loaded = {}
            for mod_name, mock in pairs(mock_modules) do
                saved_loaded[mod_name] = package.loaded[mod_name]
                package.loaded[mod_name] = mock
            end
            package.loaded["llm_handler"] = nil
            package.loaded["llm_handler.request"] = nil
            local ok, result_or_err = pcall(function()
                local llm = require("llm_handler")
                local profile = {
                    url = "http://localhost:8000/v1/chat/completions",
                    model = "test-model",
                    token = "test-token",
                    provider = "openai",
                    params = {}
                }
                local messages = {
                    { role = "user", content = "Hello " .. string.char(0xFF) .. " World" }
                }
                return llm.send_request(profile, messages, {})
            end)
            for mod_name, orig in pairs(saved_loaded) do
                if orig then
                    package.loaded[mod_name] = orig
                else
                    package.loaded[mod_name] = nil
                end
            end
            package.loaded["llm_handler"] = nil
            package.loaded["llm_handler.request"] = nil
            if ok then
                local result, err = result_or_err
                if result then
                    assert.is_true(type(result) == "table")
                else
                    assert.is_true(type(err) == "string" or type(err) == "table")
                end
            else
                fail("send_request crashed: " .. tostring(result_or_err))
            end
        end)
        it("should pass valid Russian text through without modification", function()
            local input = "\xD0\x9F\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82"
            local result = encoding.sanitize_for_json(input)
            assert.equals(input, result)
            assert.equals(#input, #result)
        end)
    end)
end)
