describe("Stream Processing", function()
    local stream_mod = require("llm_handler.stream")
    local json = require("JSON")

    -- Helper: create a mock stream object
    local function make_mock_stream(chunks)
        local idx = 0
        return {
            get_next_chunk = function(self, timeout)
                idx = idx + 1
                if idx > #chunks then
                    return nil, "EOF"
                end
                return chunks[idx], nil
            end
        }
    end

    -- Helper: create a mock profile
    local function make_mock_profile()
        return {
            params = { stream_timeout = 10 }
        }
    end

    -- Helper: create a mock provider
    local function make_mock_provider()
        return {
            extract_stream = function(json_str)
                local ok, part = pcall(json.decode, json, json_str)
                if not ok or not part or not part.choices or not part.choices[1] then
                    return nil, nil
                end
                local delta = part.choices[1].delta
                if not delta then return nil, nil end
                return delta.content, delta.reasoning_content
            end
        }
    end

    -- Mock patcher_core
    package.preload["patcher_core"] = function()
        return {
            setup_esc_monitor = function() end,
            teardown_esc_monitor = function() end,
            consume_esc = function() return false end,
            consume_sigint = function() return false end
        }
    end

    before_each(function()
        -- Reset patcher_core mock — clear cache so require() re-loads from preload
        package.loaded["patcher_core"] = nil
        package.preload["patcher_core"] = function()
            return {
                setup_esc_monitor = function() end,
                teardown_esc_monitor = function() end,
                consume_esc = function() return false end,
                consume_sigint = function() return false end
            }
        end
    end)

    it("should load the module and have process_stream function", function()
        assert.is_not_nil(stream_mod)
        assert.is_function(stream_mod.process_stream)
    end)

    it("should parse text content from SSE chunks", function()
        local chunk = "data: " .. json:encode({
            choices = {{ delta = { content = "Hello" } }}
        }) .. "\n\n"
        local chunk2 = "data: " .. json:encode({
            choices = {{ delta = { content = " World" } }}
        }) .. "\n\n"
        local chunk_done = "data: [DONE]\n\n"
        local stream = make_mock_stream({ chunk, chunk2, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()

        local collected = {}
        local result = stream_mod.process_stream(stream, profile, provider, function(token)
            table.insert(collected, token)
        end)

        assert.is_not_nil(result)
        assert.is_not_nil(result.choices)
        assert.equals("assistant", result.choices[1].message.role)
        assert.equals("Hello World", result.choices[1].message.content)
    end)

    it("should handle reasoning content", function()
        local chunk = "data: " .. json:encode({
            choices = {{ delta = { reasoning_content = "Let me think..." } }}
        }) .. "\n\n"
        local chunk_done = "data: [DONE]\n\n"
        local stream = make_mock_stream({ chunk, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local collected = {}
        local result = stream_mod.process_stream(stream, profile, provider, function(token)
            table.insert(collected, token)
        end)

        assert.is_not_nil(result)
        assert.is_not_nil(result.full_reason)
        assert.equals("Let me think...", result.full_reason)
    end)

    it("should handle EOF correctly", function()
        local stream = make_mock_stream({})
        local profile = make_mock_profile()
        local provider = make_mock_provider()

        local result = stream_mod.process_stream(stream, profile, provider, nil)

        assert.is_not_nil(result)
        assert.is_not_nil(result.choices)
        -- Empty content is expected for empty stream
        assert.equals("", result.choices[1].message.content)
    end)

    it("should handle mixed text and reasoning content", function()
        local chunk_reason = "data: " .. json:encode({
            choices = {{ delta = { reasoning_content = "Thinking..." } }}
        }) .. "\n\n"
        local chunk_text = "data: " .. json:encode({
            choices = {{ delta = { content = "Answer" } }}
        }) .. "\n\n"
        local chunk_done = "data: [DONE]\n\n"
        local stream = make_mock_stream({ chunk_reason, chunk_text, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()

        local result = stream_mod.process_stream(stream, profile, provider, nil)

        assert.is_not_nil(result)
        assert.is_not_nil(result.full_reason)
        assert.is_not_nil(result.full_text)
        assert.equals("Thinking...", result.full_reason)
        assert.equals("Answer", result.full_text)
    end)

    it("should set interrupted flag when ESC is pressed", function()
        -- Clear cached patcher_core so it re-loads from preload
        package.loaded["patcher_core"] = nil
        -- Create a mock patcher_core that simulates ESC press
        package.preload["patcher_core"] = function()
            return {
                setup_esc_monitor = function() end,
                teardown_esc_monitor = function() end,
                consume_esc = function() return true end,
                consume_sigint = function() return false end
            }
        end

        local chunk = "data: " .. json:encode({
            choices = {{ delta = { content = "Hello" } }}
        }) .. "\n\n"
        local stream = make_mock_stream({ chunk })
        local profile = make_mock_profile()
        local provider = make_mock_provider()

        local result = stream_mod.process_stream(stream, profile, provider, nil)

        assert.is_not_nil(result)
        assert.is_true(result.interrupted)
    end)
    it("should emit <thinking> tag when reasoning starts", function()
        local chunk_reason = "data: " .. json:encode({
            choices = {{ delta = { reasoning_content = "Thinking..." } }}
        }) .. "\n\n"
        local chunk_done = "data: [DONE]\n\n"
        local stream = make_mock_stream({ chunk_reason, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local collected = {}
        local result = stream_mod.process_stream(stream, profile, provider, function(token)
            table.insert(collected, token)
        end)
        assert.is_not_nil(result)
        -- The first token should contain the opening <thinking> tag
        local first_token = collected[1]
        assert.truthy(first_token:find("<thinking>"), "First token should contain <thinking> tag: " .. tostring(first_token))
        assert.equals("Thinking...", result.full_reason)
        assert.truthy(result.choices[1].message.content:find("<thinking>"), "Full content should contain <thinking> tag")
    end)
    it("should emit complete <thinking>...</thinking> wrapper for reasoning followed by text", function()
        local chunk_reason = "data: " .. json:encode({
            choices = {{ delta = { reasoning_content = "Let me think..." } }}
        }) .. "\n\n"
        local chunk_text = "data: " .. json:encode({
            choices = {{ delta = { content = "Here is the answer" } }}
        }) .. "\n\n"
        local chunk_done = "data: [DONE]\n\n"
        local stream = make_mock_stream({ chunk_reason, chunk_text, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local collected = {}
        local result = stream_mod.process_stream(stream, profile, provider, function(token)
            table.insert(collected, token)
        end)
        assert.is_not_nil(result)
        -- Verify full_content has proper <thinking>...</thinking> wrapper
        assert.truthy(result.choices[1].message.content:find("<thinking>"), "Content should start with <thinking> tag")
        assert.truthy(result.choices[1].message.content:find("</thinking>"), "Content should contain </thinking> tag")
        assert.truthy(result.choices[1].message.content:find("Here is the answer"), "Content should contain text after </thinking>")
        -- Verify separate fields
        assert.equals("Let me think...", result.full_reason)
        assert.equals("Here is the answer", result.full_text)
    end)
    it("should detect ESC interrupt on first poll", function()
        package.loaded["patcher_core"] = nil
        package.preload["patcher_core"] = function()
            return {
                setup_esc_monitor = function() end,
                teardown_esc_monitor = function() end,
                consume_esc = function() return true end,
                consume_sigint = function() return false end
            }
        end
        local chunk = "data: " .. json:encode({
            choices = {{ delta = { content = "Hello" } }}
        }) .. "\n\n"
        local stream = make_mock_stream({ chunk })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local result = stream_mod.process_stream(stream, profile, provider, nil)
        assert.is_not_nil(result)
        assert.is_true(result.interrupted)
    end)
    it("should detect SIGINT interrupt", function()
        package.loaded["patcher_core"] = nil
        package.preload["patcher_core"] = function()
            return {
                setup_esc_monitor = function() end,
                teardown_esc_monitor = function() end,
                consume_esc = function() return false end,
                consume_sigint = function() return true end
            }
        end
        local chunk = "data: " .. json:encode({
            choices = {{ delta = { content = "Hello" } }}
        }) .. "\n\n"
        local stream = make_mock_stream({ chunk })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local result = stream_mod.process_stream(stream, profile, provider, nil)
        assert.is_not_nil(result)
        assert.is_true(result.interrupted)
        assert.truthy(result.choices[1].message.content:find("INTERRUPTED"),
            "Content should contain INTERRUPTED message")
    end)
    it("should not set interrupted flag when no signal", function()
        package.loaded["patcher_core"] = nil
        package.preload["patcher_core"] = function()
            return {
                setup_esc_monitor = function() end,
                teardown_esc_monitor = function() end,
                consume_esc = function() return false end,
                consume_sigint = function() return false end
            }
        end
        local chunk1 = "data: " .. json:encode({
            choices = {{ delta = { content = "Hello" } }}
        }) .. "\n\n"
        local chunk2 = "data: " .. json:encode({
            choices = {{ delta = { content = " World" } }}
        }) .. "\n\n"
        local chunk_done = "data: [DONE]\n\n"
        local stream = make_mock_stream({ chunk1, chunk2, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local result = stream_mod.process_stream(stream, profile, provider, nil)
        assert.is_not_nil(result)
        assert.is_false(result.interrupted)
    end)
    it("should include partial content before interrupt", function()
        package.loaded["patcher_core"] = nil
        local esc_call_count = 0
        package.preload["patcher_core"] = function()
            return {
                setup_esc_monitor = function() end,
                teardown_esc_monitor = function() end,
                consume_esc = function()
                    esc_call_count = esc_call_count + 1
                    return esc_call_count >= 2
                end,
                consume_sigint = function() return false end
            }
        end
        local chunk1 = "data: " .. json:encode({
            choices = {{ delta = { content = "Hello" } }}
        }) .. "\n\n"
        local chunk2 = "data: " .. json:encode({
            choices = {{ delta = { content = " World" } }}
        }) .. "\n\n"
        local stream = make_mock_stream({ chunk1, chunk2 })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local result = stream_mod.process_stream(stream, profile, provider, nil)
        assert.is_not_nil(result)
        assert.is_true(result.interrupted)
        -- "Hello" was processed before the interrupt fired on the 2nd poll
        assert.truthy(result.choices[1].message.content:find("Hello"),
            "Content should contain 'Hello'")
        -- "World" was NOT processed because interrupt fires before chunk2 parsing
        assert.truthy(result.choices[1].message.content:find("INTERRUPTED"),
            "Content should contain INTERRUPTED message")
    end)
end)