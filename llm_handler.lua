-- llm_handler.lua
-- Модуль для взаимодействия с LLM API

local M = {}

local http_request = require("http.request") -- Requires lua-http
local json = require("JSON")                 -- Requires json.lua
local inspect = require("inspect")           -- For debugging (optional, can be removed if not needed)
local string = require("string")
local utils = require("utils")
local config_module = require("config")


local function get_config()
  return config_module.get()
end

--- Отправляет запрос к LLM API.
-- @param data_to_send Таблица с данными для отправки в API.
-- @return Таблица с ответом от API или nil в случае ошибки.
-- @return Строка с сообщением об ошибке, если есть.
function M.send_request(data_to_send)
  local cfg = get_config()
  local request, req_err = http_request.new_from_uri(cfg.API_URL)
  if not request then
    return nil, "Failed to create request object: " .. (req_err or "unknown")
  end

  request.headers:upsert(':method', 'POST')
  request.headers:upsert('Content-Type', 'application/json')
  request.headers:upsert('Accept', 'application/json')
  -- Add API Key if needed, e.g. from config
  -- if cfg.API_KEY then
  --   request.headers:upsert('Authorization', 'Bearer ' .. cfg.API_KEY)
  -- end

  local body_json, json_err = json:encode(data_to_send)
  if not body_json then
    return nil, "Failed to encode request body to JSON: " .. (json_err or "unknown")
  end
  request:set_body(body_json)

  local headers, stream, err_go = request:go()
  if not headers or not stream then
    return nil, "HTTP request failed: " .. (err_go or "network error?")
  end

  local status_code = headers:get(":status")
  local response_body_str, err_body = stream:get_body_as_string()

  if err_body then
    print("Warning: Error getting response body as string:", err_body)
  end

  if status_code ~= "200" then
    return nil, "API request failed with status " .. status_code .. ". Body: " .. (response_body_str or "N/A")
  end

  local response_data, decode_err = json:decode(response_body_str)
  if not response_data then
    return nil, "Failed to decode JSON response. Error: " .. (decode_err or "unknown") .. ". Body: " .. response_body_str
  end

  return response_data
end

--- Извлекает основной текстовый ответ из ответа LLM API.
-- @param response_data Таблица с данными ответа API.
-- @return Строка с текстовым ответом LLM или nil, если извлечь не удалось.
function M.extract_response_text(response_data)
  if not response_data then return nil end

  if response_data.choices and response_data.choices[1] and response_data.choices[1].message and response_data.choices[1].message.content then
    return response_data.choices[1].message.content
  end
  if response_data.response then -- For Ollama /generate
    return response_data.response
  end

  print("Warning: Could not extract response text from API data structure.")
  -- print(inspect(response_data)) -- For debugging
  return nil
end

--- Разделяет текст ответа LLM на основной ответ и содержимое блока <think>.
-- Если блок <think>...</think> встречается несколько раз, будет обработан только первый.
-- @param full_text Полный текстовый ответ от LLM, который может содержать блок <think>.
-- @return string Основной текст ответа LLM (без блока <think>).
-- @return string or nil Содержимое первого блока <think> (без самих тегов), или nil если блок не найден.
-- llm_handler.lua

-- llm_handler.lua

function M.extract_response_and_think_content(full_text)
  -- [[ DEBUG ]]
  print("\n================= RAW LLM OUTPUT START =================")
  print(full_text)
  print("================= RAW LLM OUTPUT END ===================\n")

  if not full_text or type(full_text) ~= "string" then
    return full_text, nil
  end

  -- 1. Вырезаем <think>
  local think_content = string.match(full_text, "<think>(.-)</think>")
  local llm_answer = full_text
  if think_content then
    llm_answer = string.gsub(full_text, "<think>.-</think>", "", 1)
  end
  
  -- 2. Умный поиск ПОСЛЕДНЕГО блока кода
  -- LLM часто пишет: "Вот код... ой нет, вот исправленный". Нам нужен последний.
  local last_code_block = nil
  
  -- Сначала ищем специфичные diff блоки
  for block in llm_answer:gmatch("```diff%s*(.-)%s*```") do
      last_code_block = block
  end
  
  -- Если diff блоков нет, ищем любые блоки
  if not last_code_block then
      for block in llm_answer:gmatch("```%w*%s*(.-)%s*```") do
          last_code_block = block
      end
  end

  if last_code_block then
      llm_answer = last_code_block
  else
      -- Если блоков нет, чистим мусор
      llm_answer = llm_answer:gsub("^```%w*\n", ""):gsub("\n```$", ""):gsub("```$", "")
  end

  if utils and utils.trim_string then
    llm_answer = utils.trim_string(llm_answer)
  end

  return llm_answer, think_content
end

--- Проверяет, является ли текст патчем в формате diff.
-- Теперь также считает патчем текст, начинающийся с "@@ ".
-- @param text Текст для проверки.
-- @return boolean true, если текст является патчем, иначе false.
function M.is_patch_format(text)
  if not text then return false end

  -- Убираем начальные и конечные пробелы/переводы строк для более надежной проверки
  local trimmed_text = utils.trim_string(text)

  -- Проверяем, начинается ли текст с "@@ " (стандартное начало hunk'а в diff)
  if trimmed_text:match("^@@ ") then
    return true
  end

  -- Оставляем старые проверки для обратной совместимости или полных diff'ов
  return trimmed_text:match("^--- a/.-\n%+%+%+ b/.-\n@@") or                                                -- Standard git diff header
      trimmed_text:match("\n--- old/.-\n%+%+%+ new/.-\n@@") or                                              -- Common variations
      (trimmed_text:match("\n--- ") and trimmed_text:match("\n%+%+%+ ") and trimmed_text:match("\n@@ "))    -- Original simpler check
end

--- Ищет в тексте запрос на просмотр файла.
-- @param text Текст для поиска.
-- @return string Путь к файлу, если найден, иначе nil.
function M.find_file_request(text)
  if not text then return nil end
  local path = text:match("[Ss]how me file `([^`]+)`") or
      text:match("[Rr]ead file `([^`]+)`") or
      text:match("[Cc]ontent of `([^`]+)`") or
      text:match("[Pp]rovide file `([^`]+)`") or
      text:match("[Ss]how me `([^`]+%.%w+)`") or
      text:match("[Pp]rovide `([^`]+%.%w+)`")
  if path then
    if utils and utils.trim_string then
      return utils.trim_string(path)
    else
      return path
    end
  end
  return nil
end

return M
