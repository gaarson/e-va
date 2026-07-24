local json = require("JSON")
local utils = require("utils")
require("luacov")
print("=== REASONING SYSTEM TEST SUITE ===\n")

local passed = 0
local failed = 0

local function assert_true(label, condition)
    if condition then
        print(string.format("  [PASS] %s", label))
        passed = passed + 1
    else
        print(string.format("  [FAIL] %s", label))
        failed = failed + 1
    end
end


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


print("--- TEST 1: Reasoning tag stripping ---")

local correct_close = "</think>"


-- Realistic LLM output: reasoning tags are CLOSED

local test_payload = "<think>\nThis is reasoning\n</think>\n\ndelegate_plan:\n{\"plan\":[]}"
local fixed_result = strip_balanced_tags(test_payload, "<think>", correct_close)
assert_true("Strips reasoning tags correctly", not fixed_result:find("<think>"))
assert_true("Preserves payload after tags", fixed_result:find("delegate_plan"))

local complex_payload = "<think>\nStep 1: analyze\nStep 2: decide\n</think>\n\n{\"plan\": [{\"file\": \"a.lua\", \"instruction\": \"fix\"}], \"memo\": \"ctx\"}"
local complex_fixed = strip_balanced_tags(complex_payload, "<think>", correct_close)

assert_true("Complex reasoning stripped", not complex_fixed:find("<think>"))
assert_true("Complex payload preserved", complex_fixed:find('"plan"'))


local multi_block = "<think>\nfirst thought\n</think>\n\nsome text\n<think>\nsecond thought\n</think>\n\nfinal payload"
local stripped = strip_balanced_tags(multi_block, "<think>", correct_close)

assert_true("Multiple reasoning blocks all stripped", not stripped:find("<think>"))
assert_true("Text between blocks preserved", stripped:find("some text"))
assert_true("Final payload preserved", stripped:find("final payload"))


print("\n--- TEST 2: Streaming reasoning assembly ---")

local full_content = ""
local full_reason = ""
local full_text = ""
local in_reasoning = false

local function process_chunk(c_text, c_reason)
    if c_reason and c_reason ~= "" then
        if not in_reasoning then
            in_reasoning = true
            full_content = full_content .. "<think>\n" .. c_reason
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

assert_true("full_reason captures all reasoning", full_reason == "Thinking about the problem...and considering options")
assert_true("full_text captures all text", full_text == "Hello world more text")
assert_true("full_content has reasoning wrapped in tags", full_content:find("<think>"))
assert_true("full_content transitions from reasoning to text", full_content:find("\n\nHello"))

print("\n--- TEST 3: Non-streaming reasoning extraction ---")

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

assert_true("Includes reasoning_content", extracted:find("Internal reasoning steps"))
assert_true("Wraps reasoning in tags", extracted:find("<think>"))
assert_true("Includes final content", extracted:find("Final answer here"))


print("\n--- TEST 4: Streaming extraction ---")
local reasoning_json = json:encode({choices={{delta={reasoning_content="reason chunk"}}}})
local text_json = json:encode({choices={{delta={content="text chunk"}}}})


local c_text, c_reason = openai_provider.extract_stream(reasoning_json)
assert_true("Extracts reasoning_content", c_reason == "reason chunk")
assert_true("Returns nil content for reasoning-only", c_text == nil)


c_text, c_reason = openai_provider.extract_stream(text_json)
assert_true("Extracts content", c_text == "text chunk")
assert_true("Returns nil reasoning for text-only", c_reason == nil)


print("\n--- TEST 5: Edge cases ---")

local empty_reason = json:encode({choices={{delta={reasoning_content=""}}}})
c_text, c_reason = openai_provider.extract_stream(empty_reason)
assert_true("Empty reasoning_content returns empty string", c_reason == "")


local no_delta = json:encode({choices={{}}})
c_text, c_reason = openai_provider.extract_stream(no_delta)
assert_true("Missing delta returns nil", c_text == nil and c_reason == nil)


c_text, c_reason = openai_provider.extract_stream("not json at all")
assert_true("Invalid JSON returns nil", c_text == nil and c_reason == nil)


print("\n--- TEST 6: Source code verification ---")

local f_src = io.open("multi_stage_executor.lua", "r")

if f_src then
    local src = f_src:read("*a")
    f_src:close()
    assert_true("multi_stage_executor uses correct close tag", src:find("strip_balanced_tags.*think>"))
    assert_true("multi_stage_executor does NOT use buggy tag", not src:find("<//think>"))
end


local f2 = io.open("context_compressor.lua", "r")
if f2 then
    local src2 = f2:read("*a")
    f2:close()
    assert_true("context_compressor has thinking_patterns array", src2:find("thinking_patterns"))
end


print("\n--- TEST 7: Compressor integration ---")

local compressor = require("context_compressor")


local thinking_content = "Some introductory text here that provides context for the following analysis.\n<thinking>\nThis is a long reasoning block that contains important decisions and conclusions about the task at hand. We need to consider multiple factors.\n</thinking>\nMore concluding text here."

local compressed1 = compressor.compress_assistant_thinking(thinking_content, compressor.DEFAULT_CONFIG)

assert_true("Compresses <thinking> tags", not compressed1:find("<thinking>"))


local reason_content = "Some introductory text here that provides context for the following analysis.\n" .. "<think>" .. "\nThis is a long reasoning block that contains important decisions and conclusions about the task at hand. We need to consider multiple factors.\n" .. "</think>" .. "\nMore concluding text here."

local compressed2 = compressor.compress_assistant_thinking(reason_content, compressor.DEFAULT_CONFIG)

assert_true("Compresses reasoning tags", not compressed2:find("<think>"))


assert_true("is_compressible detects reasoning tags",
    compressor.is_compressible({role="assistant", content=reason_content}, compressor.DEFAULT_CONFIG))
assert_true("is_compressible detects <thinking> tags",
    compressor.is_compressible({role="assistant", content=thinking_content}, compressor.DEFAULT_CONFIG))


print(string.format("\n=== RESULTS: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    os.exit(1)
end
