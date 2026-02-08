-- llm_handler.lua
local M = {}
local http = require("http.request")
local json = require("JSON") 
local config = require("config").get()

function M.send_request(payload)
    local req = http.new_from_uri(config.API_URL)
    req.headers:upsert(":method", "POST")
    req.headers:upsert("content-type", "application/json")

    -- УБИРАЕМ ЭТУ СТРОКУ, она вызывает ошибку в текущей версии библиотеки
    -- req:set_timeout(120000) 

    local body = json:encode(payload)
    if not body then return nil, "JSON Encode error" end

    req:set_body(body)

    -- Отправляем запрос
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
    -- Удаляем обертку ```xml ... ``` или ```json ...``` если модель их добавила
    local clean = text:gsub("^```%w*\n", ""):gsub("\n```$", "")
    return clean
end

return M
