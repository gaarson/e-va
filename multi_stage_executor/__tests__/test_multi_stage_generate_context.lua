-- Tests for dynamic generate-stage context selection based on thinking mode
local describe = describe or function(name, fn) print("  " .. name); fn() end
local it = it or function(name, fn) local ok, err = pcall(fn); if not ok then error(err) end; print("    ✓ " .. name) end
local assert = require("luassert")
-- Helper: simulate the prefix selection logic from run_multi_stage_loop
local function simulate_generate_prefix(agent_cfg, step, base_messages, generate_prefix, system_context)
    local model_has_thinking = agent_cfg.chat_template_kwargs and agent_cfg.chat_template_kwargs.enable_thinking == true
    
    local prefix_to_use
    if model_has_thinking then
        -- Thinking mode: minimal prefix
        if system_context then
            prefix_to_use = {{ role = 'system', content = system_context }}
        else
            prefix_to_use = generate_prefix
        end
    else
        -- No thinking: full history
        prefix_to_use = base_messages
    end
    return prefix_to_use, model_has_thinking
end
local function simulate_stage_overrides(agent_cfg)
    local model_has_thinking = agent_cfg.chat_template_kwargs and agent_cfg.chat_template_kwargs.enable_thinking == true
    return {
        intent   = {},
        generate = model_has_thinking and {} or { chat_template_kwargs = { enable_thinking = false }, thinking_token_budget = 0 },
        review   = {},
    }
end
describe("Generate stage context selection (thinking-aware)", function()
    local base_messages = {
        { role = "system", content = "FULL SYSTEM PROMPT WITH TOOLS" },
        { role = "user", content = "Hello" },
        { role = "assistant", content = "Hi there" },
    }
    local generate_prefix = {{ role = "system", content = "RAW OUTPUT MODE" }}
    local system_context = "SOURCE FILES CONTEXT"
    it("thinking ON: uses minimal prefix (system_context)", function()
        local agent_cfg = { chat_template_kwargs = { enable_thinking = true } }
        local prefix, has_thinking = simulate_generate_prefix(agent_cfg, nil, base_messages, generate_prefix, system_context)
        assert.is_true(has_thinking)
        assert.equals(1, #prefix)
        assert.equals("SOURCE FILES CONTEXT", prefix[1].content)
    end)
    it("thinking ON: uses generate_prefix when no system_context", function()
        local agent_cfg = { chat_template_kwargs = { enable_thinking = true } }
        local prefix, _ = simulate_generate_prefix(agent_cfg, nil, base_messages, generate_prefix, nil)
        assert.equals(1, #prefix)
        assert.equals("RAW OUTPUT MODE", prefix[1].content)
    end)
    it("thinking OFF: uses full base_messages", function()
        local agent_cfg = { chat_template_kwargs = { enable_thinking = false } }
        local prefix, has_thinking = simulate_generate_prefix(agent_cfg, nil, base_messages, generate_prefix, system_context)
        assert.falsy(has_thinking)
        assert.equals(#base_messages, #prefix)
        assert.equals("FULL SYSTEM PROMPT WITH TOOLS", prefix[1].content)
    end)
    it("thinking OFF (no chat_template_kwargs): uses full base_messages", function()
        local agent_cfg = {}
        local prefix, has_thinking = simulate_generate_prefix(agent_cfg, nil, base_messages, generate_prefix, system_context)
        assert.falsy(has_thinking)
        assert.equals(#base_messages, #prefix)
    end)
    it("thinking ON: STAGE_OVERRIDES.generate is empty (no override)", function()
        local agent_cfg = { chat_template_kwargs = { enable_thinking = true } }
        local overrides = simulate_stage_overrides(agent_cfg)
        assert.is_table(overrides.generate)
        -- Empty table means no override — model keeps its default thinking
        assert.is_nil(overrides.generate.chat_template_kwargs)
    end)
    it("thinking OFF: STAGE_OVERRIDES.generate forces enable_thinking=false", function()
        local agent_cfg = { chat_template_kwargs = { enable_thinking = false } }
        local overrides = simulate_stage_overrides(agent_cfg)
        assert.is_table(overrides.generate.chat_template_kwargs)
        assert.is_false(overrides.generate.chat_template_kwargs.enable_thinking)
        assert.equals(0, overrides.generate.thinking_token_budget)
    end)
    it("thinking OFF (nil config): STAGE_OVERRIDES.generate forces enable_thinking=false", function()
        local agent_cfg = {}
        local overrides = simulate_stage_overrides(agent_cfg)
        assert.is_false(overrides.generate.chat_template_kwargs.enable_thinking)
    end)
end)
describe("Reasoning preservation in tail", function()
    -- Simulate the tail insertion logic
    local function simulate_tail_insert(response_data, tail)
        local content = ""
        if response_data.choices and response_data.choices[1] and response_data.choices[1].message then
            content = response_data.choices[1].message.content or ""
        end
        local full_reason = response_data.full_reason or ""
        if full_reason ~= "" then
            content = "<thinking>\n" .. full_reason .. "\n</thinking>\n\n" .. content
        end
        table.insert(tail, { role = "assistant", content = content })
        return tail
    end
    it("preserves reasoning when full_reason is present", function()
        local response_data = {
            choices = {{ message = { content = "The answer is 42" } }},
            full_reason = "Let me think about this problem step by step..."
        }
        local tail = {}
        simulate_tail_insert(response_data, tail)
        assert.equals(1, #tail)
        assert.is_not_nil(tail[1].content:find("<thinking>"))
        assert.is_not_nil(tail[1].content:find("Let me think about this problem"))
        assert.is_not_nil(tail[1].content:find("</thinking>"))
        assert.is_not_nil(tail[1].content:find("The answer is 42"))
    end)
    it("does not add thinking tags when full_reason is empty", function()
        local response_data = {
            choices = {{ message = { content = "Just content" } }},
            full_reason = ""
        }
        local tail = {}
        simulate_tail_insert(response_data, tail)
        assert.equals(1, #tail)
        assert.is_nil(tail[1].content:find("<thinking>"))
        assert.equals("Just content", tail[1].content)
    end)
    it("does not add thinking tags when full_reason is nil", function()
        local response_data = {
            choices = {{ message = { content = "No reasoning here" } }}
            -- no full_reason field
        }
        local tail = {}
        simulate_tail_insert(response_data, tail)
        assert.equals(1, #tail)
        assert.is_nil(tail[1].content:find("<thinking>"))
    end)
    it("reasoning from review is visible to next generate iteration", function()
        -- Simulate: review stage produces reasoning, then generate sees it in tail
        local tail = {}
        
        -- Review response with reasoning
        local review_response = {
            choices = {{ message = { content = "<REVIEW>\nVERDICT: REVISE\nCORRECTION: Fix the off-by-one error\n</REVIEW>" } }},
            full_reason = "I noticed the loop condition uses < instead of <=, which causes an off-by-one error at the boundary."
        }
        simulate_tail_insert(review_response, tail)
        
        -- Verify the reasoning is in the tail (visible to next generate)
        assert.is_not_nil(tail[1].content:find("off-by-one error", 1, true))
        assert.is_not_nil(tail[1].content:find("<thinking>"))
    end)
end)
print("\nAll generate-context tests passed.\n")
