-- FILE: llm_providers.lua
local M = {}
local utils = require("utils")

M.registry = {}

function M.register(name, interface)
    M.registry[name] = interface
end

function M.get(name)
    return M.registry[name] or M.registry["openai"] -- Fallback
end

-- ==========================================
-- Провайдер по умолчанию: OpenAI / Qwen / Gemma
-- ==========================================
M.register("openai", {
    build_payload = function(profile, messages, options)
        local override_params = options and options.override_params or {}
        local payload = {
            model = profile.model,
            messages = messages,
        }
        if profile.params then
            payload = utils.deep_merge(payload, profile.params)
        end
        if override_params then
            payload = utils.deep_merge(payload, override_params)
        end
        if payload.stream == nil then payload.stream = false end
        return payload
    end,

    extract_sync = function(data)
        if type(data) ~= "table" or not data.choices or not data.choices[1] then return nil end
        local msg = data.choices[1].message
        if not msg then return nil end
        
        local content = msg.content or ""
        if msg.reasoning_content and msg.reasoning_content ~= "" then
            content = "<think>\n" .. msg.reasoning_content .. "\n</think>\n" .. content
        end
        return content
    end,

    extract_stream = function(json_str)
        local json = require("JSON")
        local ok, part = pcall(json.decode, json, json_str)
        if not ok or not part or not part.choices or not part.choices[1] then return nil, nil end
        
        local delta = part.choices[1].delta
        if not delta then return nil, nil end
        
        return delta.content, delta.reasoning_content
    end
})

-- Пример: Anthropic (Claude 3.5 Sonnet)
M.register("anthropic", {
    build_payload = function(profile, messages, options)
        -- Перехват системного промпта, так как Anthropic требует его на верхнем уровне
        local system_msg = ""
        local filtered_msgs = {}
        for _, m in ipairs(messages) do
            if m.role == "system" then system_msg = system_msg .. m.content .. "\n"
            else table.insert(filtered_msgs, m) end
        end
        
        local payload = {
            model = profile.model,
            system = system_msg ~= "" and utils.trim(system_msg) or nil,
            messages = filtered_msgs,
            max_tokens = profile.params.max_tokens or 4096
        }
        if profile.params.stream ~= nil then payload.stream = profile.params.stream end
        return payload
    end,
    
    extract_sync = function(data)
        if type(data) ~= "table" or not data.content or not data.content[1] then return nil end
        return data.content[1].text or ""
    end,

    extract_stream = function(json_str)
        local json = require("JSON")
        local ok, part = pcall(json.decode, json, json_str)
        if not ok or not part then return nil, nil end
        
        if part.type == "content_block_delta" and part.delta and part.delta.text then
            return part.delta.text, nil
        end
        return nil, nil
    end
})

return M
