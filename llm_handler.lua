local M = {}
local http = require("http.request")
local json = require("JSON")
local config = require("config").get()

local function merge_tables(t1, t2)
    local res = {}
    if t1 then for k, v in pairs(t1) do res[k] = v end end
    if t2 then for k, v in pairs(t2) do res[k] = v end end
    return res
end

function M.send_request(messages, override_params)
    local req = http.new_from_uri(config.API_URL)
    req.headers:upsert(":method", "POST")
    req.headers:upsert("content-type", "application/json")

    local payload = merge_tables({
        model = config.API_MODEL,
        messages = messages,
        stream = false
    }, config.GENERATION_PARAMS)

    if override_params then
        payload = merge_tables(payload, override_params)
    end

    local body = json:encode(payload)
    if not body then return nil, "JSON Encode error" end

    req:set_body(body)

    local headers, stream = req:go()
    if not headers then return nil, "Connection failed" end

    local body_str = stream:get_body_as_string()
    if headers:get(":status") ~= "200" then
        return nil, "HTTP " .. headers:get(":status") .. ": " .. body_str
    end

    return json:decode(body_str)
end

function M.extract_content(data)
    if not data or not data.choices or not data.choices[1] then return nil end
    return data.choices[1].message.content
end

function M.clean_code_blocks(text)
    if not text then return "" end
    local clean = text:gsub("^```%w*\n", ""):gsub("\n```$", "")
    return clean
end

return M
