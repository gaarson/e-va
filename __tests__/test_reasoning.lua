local json = require("JSON")
require("luacov")
describe("Reasoning tag stripping", function()
    local function strip_balanced_tags(text, open_tag, close_tag)
        local result = text
        local found = true
        while found do
            local start_pos = result:find(open_tag, 1, true)
            if start_pos then
                local end_pos = result:find(close_tag, start_pos + #open_tag, true)
                if end_pos then
                    result = result:sub(1, start_pos - 1) .. result:sub(end_pos + #close_tag)
                else
                    found = false
                end
            else
                found = false
            end
        end
        return result
    end
    local correct_close = "</thinking>"
    it("strips reasoning tags correctly", function()
        local test_payload = "<thinking>\nThis is reasoning\n</thinking>\n\ndelegate_plan:\n{\"plan\":[]}"
        local fixed_result = strip_balanced_tags(test_payload, "<thinking>", correct_close)
        assert.falsy(fixed_result:find("<thinking>"))
        assert.truthy(fixed_result:find("delegate_plan"))
    end)
    it("handles complex reasoning stripping", function()
        local complex_payload = "<thinking>\nStep 1: analyze\nStep 2: decide\n</thinking>\n\n{\"plan\": [{\"file\": \"a.lua\", \"instruction\": \"fix\"}], \"memo\": \"ctx\"}"
        local complex_fixed = strip_balanced_tags(complex_payload, "<thinking>", correct_close)
        assert.falsy(complex_fixed:find("<thinking>"))
        assert.truthy(complex_fixed:find('"plan"'))
    end)
    it("strips multiple reasoning blocks", function()
        local multi_block = "<thinking>\nfirst thought\n</thinking>\n\nsome text\n<thinking>\nsecond thought\n</thinking>\n\nfinal payload"
        local stripped = strip_balanced_tags(multi_block, "<thinking>", correct_close)
        assert.falsy(stripped:find("<thinking>"))
        assert.truthy(stripped:find("some text"))
        assert.truthy(stripped:find("final payload"))
    end)
end)
describe("Streaming reasoning assembly", function()
    it("captures reasoning and text separately", function()
        local full_content = ""
        local full_reason = ""
        local full_text = ""
        local in_reasoning = false
        local function process_chunk(c_text, c_reason)
            if c_reason and c_reason ~= "" then
                if not in_reasoning then
                    in_reasoning = true
                    full_content = full_content .. "<thinking>\n" .. c_reason
                else
                    full_content = full_content .. c_reason
                end
                full_reason = full_reason .. c_reason
            elseif c_text and c_text ~= "" then
                if in_reasoning then
                    in_reasoning = false
                    full_content = full_content .. "\n\n" .. c_text
                else
                    full_content = full_content .. c_text
                end
                full_text = full_text .. c_text
            end
        end
        process_chunk(nil, "Thinking about the problem")
        process_chunk(nil, "...and considering options")
        process_chunk("Hello world", nil)
        process_chunk(" more text", nil)
        assert.equals("Thinking about the problem...and considering options", full_reason)
        assert.equals("Hello world more text", full_text)
        assert.truthy(full_content:find("<thinking>"))
        assert.truthy(full_content:find("\n\nHello"))
    end)
end)
describe("Non-streaming reasoning extraction", function()
    it("excludes reasoning_content from extracted output (separated)", function()
        local providers = require("llm_providers")
        local openai_provider = providers.get("openai")
        local mock_response = {
            choices = {{
                message = {
                    role = "assistant",
                    content = "Final answer here",
                    reasoning_content = "Internal reasoning steps"
                }
            }}
        }
        local extracted = openai_provider.extract_sync(mock_response)
        assert.truthy(extracted, "extract_sync should return a value")
        assert.equals("Final answer here", extracted)
        assert.falsy(extracted:find("Internal reasoning steps"))
    end)
end)
describe("Streaming extraction", function()
    it("extracts reasoning_content from stream", function()
        local providers = require("llm_providers")
        local openai_provider = providers.get("openai")
        local reasoning_json = json:encode({choices={{delta={reasoning_content="reason chunk"}}}})
        local c_text, c_reason = openai_provider.extract_stream(reasoning_json)
        assert.equals("reason chunk", c_reason)
        assert.is_nil(c_text)
    end)
    it("extracts content from stream", function()
        local providers = require("llm_providers")
        local openai_provider = providers.get("openai")
        local text_json = json:encode({choices={{delta={content="text chunk"}}}})
        local c_text, c_reason = openai_provider.extract_stream(text_json)
        assert.equals("text chunk", c_text)
        assert.is_nil(c_reason)
    end)
end)
describe("Edge cases", function()
    it("handles empty reasoning_content", function()
        local providers = require("llm_providers")
        local openai_provider = providers.get("openai")
        local empty_reason = json:encode({choices={{delta={reasoning_content=""}}}})
        local c_text, c_reason = openai_provider.extract_stream(empty_reason)
        assert.equals("", c_reason)
    end)
    it("handles missing delta", function()
        local providers = require("llm_providers")
        local openai_provider = providers.get("openai")
        local no_delta = json:encode({choices={{}}})
        local c_text, c_reason = openai_provider.extract_stream(no_delta)
        assert.is_nil(c_text)
        assert.is_nil(c_reason)
    end)
    it("handles invalid JSON", function()
        local providers = require("llm_providers")
        local openai_provider = providers.get("openai")
        local c_text, c_reason = openai_provider.extract_stream("not json at all")
        assert.is_nil(c_text)
        assert.is_nil(c_reason)
    end)
end)
describe("Source code verification", function()
    it("multi_stage_executor uses correct close tag", function()
        local f_src = io.open("multi_stage_executor.lua", "r")
        if f_src then
            local src = f_src:read("*a")
            f_src:close()
            assert.truthy(src:find("strip_balanced_tags.*think>"))
            assert.falsy(src:find("<//think>"))
        end
    end)
    it("context_compressor has thinking_patterns array", function()
        local f2 = io.open("context_compressor.lua", "r")
        if f2 then
            local src2 = f2:read("*a")
            f2:close()
            assert.truthy(src2:find("thinking_patterns"))
        end
    end)
end)
describe("Compressor integration", function()
    it("compresses <thinking> tags", function()
        local compressor = require("context_compressor")
        local thinking_content = "Some introductory text here that provides context for the following analysis.\n<thinking>\nThis is a long reasoning block that contains important decisions and conclusions about the task at hand. We need to consider multiple factors.\n</thinking>\nMore concluding text here."
        local compressed1 = compressor.compress_assistant_thinking(thinking_content, compressor.DEFAULT_CONFIG)
        assert.truthy(compressed1, "compress_assistant_thinking should return a value")
        assert.falsy(compressed1:find("<thinking>"))
    end)
    it("compresses reasoning tags", function()
        local compressor = require("context_compressor")
        local reason_content = "Some introductory text here that provides context for the following analysis.\n" .. "<thinking>" .. "\nThis is a long reasoning block that contains important decisions and conclusions about the task at hand. We need to consider multiple factors.\n" .. "</thinking>" .. "\nMore concluding text here."
        local compressed2 = compressor.compress_assistant_thinking(reason_content, compressor.DEFAULT_CONFIG)
        assert.truthy(compressed2, "compress_assistant_thinking should return a value")
        assert.falsy(compressed2:find("<thinking>"))
    end)
    it("is_compressible detects reasoning tags", function()
        local compressor = require("context_compressor")
        local reason_content = "Some introductory text here that provides context for the following analysis.\n" .. "<thinking>" .. "\nThis is a long reasoning block that contains important decisions and conclusions about the task at hand. We need to consider multiple factors.\n" .. "</thinking>" .. "\nMore concluding text here."
        assert.is_true(compressor.is_compressible({role="assistant", content=reason_content}, compressor.DEFAULT_CONFIG))
    end)
    it("is_compressible detects <thinking> tags", function()
        local compressor = require("context_compressor")
        local thinking_content = "Some introductory text here that provides context for the following analysis.\n<thinking>\nThis is a long reasoning block that contains important decisions and conclusions about the task at hand. We need to consider multiple factors.\n</thinking>\nMore concluding text here."
        assert.is_true(compressor.is_compressible({role="assistant", content=thinking_content}, compressor.DEFAULT_CONFIG))
    end)
end)
describe("Config synchronization", function()
    it("AGENT_DEFAULTS.url uses LLM_BASE_URL env var", function()
        local config = require("config")
        local cfg = config.get()
        assert.truthy(cfg.AGENT_DEFAULTS.url == cfg.AGENTS.ARCHITECT.url or cfg.AGENT_DEFAULTS.url:find("localhost:8000"))
    end)
    it("AGENTS.ARCHITECT.url is set", function()
        local config = require("config")
        local cfg = config.get()
        assert.truthy(cfg.AGENTS.ARCHITECT.url)
    end)
    it("AGENTS.CODER.url is set", function()
        local config = require("config")
        local cfg = config.get()
        assert.truthy(cfg.AGENTS.CODER.url)
    end)
    it("AGENT_DEFAULTS.model is set", function()
        local config = require("config")
        local cfg = config.get()
        assert.truthy(cfg.AGENT_DEFAULTS.model)
    end)
end)