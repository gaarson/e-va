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

function M.send_request(profile, messages, options)
    options = options or {}
    local override_params = options.override_params
    local on_token_cb = options.on_token 

    if not profile or not profile.url then
        return nil, "Invalid Profile"
    end

    local req = http.new_from_uri(profile.url)
    req.headers:upsert(":method", "POST")
    req.headers:upsert("content-type", "application/json")
    req.headers:upsert("accept", "text/event-stream") 

    local headers, stream = req:go(60) 
    if not headers then return nil, "Connection timeout or failed" end

    local payload = merge_tables({
        model = profile.model,
        messages = messages,
        stream = profile.params.stream or false
    }, profile.params or {})

    if override_params then
        payload = merge_tables(payload, override_params)
    end

    local body = json:encode(payload)
    req:set_body(body)

    local headers, stream = req:go()
    if not headers then return nil, "Connection failed" end

    local status = headers:get(":status")
    if status ~= "200" then
        local err_body = ""
        if stream then
            pcall(function() err_body = stream:get_body_as_string() end)
        end
        logger.error("API Error: " .. status, err_body)
        return nil, "HTTP " .. status
    end

    if not payload.stream then
        local body_str = stream:get_body_as_string()
        local response = json:decode(body_str)
        return response
    end

    local full_content = ""
    local buffer = ""

    for chunk in stream:each_chunk() do
        buffer = buffer .. chunk

        while true do
            local line_end = buffer:find("\n")
            if not line_end then break end

            local line = buffer:sub(1, line_end - 1)
            buffer = buffer:sub(line_end + 1)
            
            line = line:gsub("\r", ""):gsub("^%s+", "") 
            
            if line:sub(1, 5) == "data:" then
                local json_str = line:sub(6)
                if json_str:match("%[DONE%]") then
                else
                    local ok, part = pcall(json.decode, json, json_str)
                    if ok and part and part.choices and part.choices[1] then
                        local delta = part.choices[1].delta
                        if delta and delta.content then
                            local token = delta.content
                            full_content = full_content .. token
                            if on_token_cb then on_token_cb(token) end
                        end
                    end
                end
            end
        end
    end

    return {
        choices = {
            {
                message = {
                    role = "assistant",
                    content = full_content
                }
            }
        }
    }
end

function M.extract_content(data)
    if not data or not data.choices or not data.choices[1] then return nil end
    return data.choices[1].message.content
end

function M.clean_code_blocks(text)
    if not text then return "" end
    return text:gsub("^```%w*\n", ""):gsub("\n```$", "")
end

return M
