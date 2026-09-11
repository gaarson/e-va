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
    it("should handle reasoning content separately from text", function()
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
        -- Reasoning is stored separately
        assert.equals("Let me think...", result.full_reason)
        -- Content should NOT contain reasoning (no thinking tags)
        assert.equals("", result.choices[1].message.content)
        -- full_text should be empty (no text tokens were sent)
        assert.equals("", result.full_text)
    end)
    it("should handle EOF correctly", function()
        local stream = make_mock_stream({})
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local result = stream_mod.process_stream(stream, profile, provider, nil)
        assert.is_not_nil(result)
        assert.is_not_nil(result.choices)
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
        -- Reasoning and text are fully separated
        assert.equals("Thinking...", result.full_reason)
        assert.equals("Answer", result.full_text)
        -- Content contains ONLY text, no reasoning tags
        assert.equals("Answer", result.choices[1].message.content)
        -- No thinking tags in content
        assert.falsy(result.choices[1].message.content:find("<thinking>"))
        assert.falsy(result.choices[1].message.content:find("</thinking>"))
    end)
    it("should set interrupted flag when ESC is pressed", function()
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
    it("should NOT include thinking tags in content when reasoning precedes text", function()
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
        -- Content should be text-only, NO thinking tags
        local content = result.choices[1].message.content
        assert.equals("Here is the answer", content)
        assert.falsy(content:find("<thinking>"), "Content must NOT contain <thinking> tag")
        assert.falsy(content:find("</thinking>"), "Content must NOT contain </thinking> tag")
        -- Separate fields are correct
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
        assert.truthy(result.choices[1].message.content:find("Hello"),
            "Content should contain 'Hello'")
        assert.truthy(result.choices[1].message.content:find("INTERRUPTED"),
            "Content should contain INTERRUPTED message")
    end)
    it("should handle reasoning and text in the same chunk", function()
        local chunk = "data: " .. json:encode({
            choices = {{ delta = {
                reasoning_content = "Final thought",
                content = "The answer is 42"
            }}}
        }) .. "\n\n"
        local chunk_done = "data:"
        local stream = make_mock_stream({ chunk, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local result = stream_mod.process_stream(stream, profile, provider, nil)
        assert.is_not_nil(result)
        assert.equals("Final thought", result.full_reason)
        assert.equals("The answer is 42", result.full_text)
        -- Content should be text-only, no thinking tags
        local content = result.choices[1].message.content
        assert.equals("The answer is 42", content)
        assert.falsy(content:find("<thinking>"), "Content must NOT contain <thinking> tag")
    end)
    it("should accumulate multiple reasoning chunks into full_reason", function()
        local chunk1 = "data: " .. json:encode({
            choices = {{ delta = { reasoning_content = "Step one. " } }}
        }) .. "\n\n"
        local chunk2 = "data: " .. json:encode({
            choices = {{ delta = { reasoning_content = "Step two." } }}
        }) .. "\n\n"
        local chunk3 = "data: " .. json:encode({
            choices = {{ delta = { content = "Done" } }}
        }) .. "\n\n"
        local chunk_done = "data: [DONE]\n\n"
        local stream = make_mock_stream({ chunk1, chunk2, chunk3, chunk_done })
        local profile = make_mock_profile()
        local provider = make_mock_provider()
        local result = stream_mod.process_stream(stream, profile, provider, nil)
        assert.is_not_nil(result)
        assert.equals("Step one. Step two.", result.full_reason)
        assert.equals("Done", result.full_text)
        assert.equals("Done", result.choices[1].message.content)
    end)
end)
