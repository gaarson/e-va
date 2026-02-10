local M = {}
local http = require("http.request")
local json = require("JSON")
local logger = require("logger")

local function merge_tables(t1, t2)
    local res = {}
    if t1 then for k, v in pairs(t1) do res[k] = v end end
    if t2 then for k, v in pairs(t2) do res[k] = v end end
    return res
end

-- profile: таблица из config (LLM_MAIN или LLM_SCOUT)
function M.send_request(profile, messages, override_params)
    if not profile or not profile.url then
        logger.error("LLM Profile missing or invalid URL")
        return nil, "Invalid Profile"
    end

    local req = http.new_from_uri(profile.url)
    req.headers:upsert(":method", "POST")
    req.headers:upsert("content-type", "application/json")

    -- Слияние параметров: Defaults -> Profile Params -> Override
    local payload = merge_tables({
        model = profile.model,
        messages = messages,
        stream = false
    }, profile.params or {})

    if override_params then
        payload = merge_tables(payload, override_params)
    end
    
    -- logger.debug("Request Payload", payload) -- Раскомментируй для дебага

    local body = json:encode(payload)
    if not body then return nil, "JSON Encode error" end

    req:set_body(body)

    local headers, stream = req:go()
    if not headers then return nil, "Connection failed" end

    local body_str = stream:get_body_as_string()
    local status = headers:get(":status")
    
    if status ~= "200" then
        logger.error("API Error: " .. status, body_str)
        return nil, "HTTP " .. status .. ": " .. body_str
    end

    local response = json:decode(body_str)
    return response
end

function M.extract_content(data)
    if not data or not data.choices or not data.choices[1] then return nil end
    return data.choices[1].message.content
end

function M.clean_code_blocks(text)
    if not text then return "" end
    -- Убираем обертку markdown, если она есть
    local clean = text:gsub("^```%w*\n", ""):gsub("\n```$", "")
    return clean
end

return M
