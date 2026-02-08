-- patcher.lua
local M = {}

-- Функция для экранирования магических символов Lua pattern, 
-- чтобы использовать plain text search
local function escape_pattern(text)
    return text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

--- Применяет изменения формата SEARCH/REPLACE к содержимому файла
-- @param original_content Строка: исходный код файла
-- @param llm_response Строка: ответ от LLM с блоками
-- @return boolean success
-- @return string result_content (или сообщение об ошибке)
function M.apply_search_replace(original_content, llm_response)
    if not original_content or not llm_response then
        return false, "Invalid input: content or response is nil"
    end

    local current_content = original_content
    local changes_count = 0
    
    -- Паттерн для захвата блоков. 
    -- Используем (.-) для нежадного захвата содержимого между маркерами.
    for search_block, replace_block in llm_response:gmatch("<<<<<<< SEARCH\n(.-)\n=======\n(.-)\n>>>>>>> REPLACE") do
        
        -- Убираем возможный лишний перенос строки в конце search_block, если LLM его добавила случайно,
        -- но тут надо быть осторожным. Для начала пробуем "как есть".
        
        -- Ищем точное вхождение SEARCH блока в текущем контенте.
        -- true в 4-м аргументе string.find означает "plain search" (без pattern matching magic)
        local start_idx, end_idx = current_content:find(search_block, 1, true)
        
        if not start_idx then
            -- Попытка Fallback: иногда LLM стрипает whitespace в начале/конце.
            -- Можно добавить логику "trim", но для начала вернем строгую ошибку.
            return false, "CRITICAL: Could not find SEARCH block in the file. Context mismatch.\nBLOCK:\n" .. search_block
        end

        -- Выполняем замену (String Splicing)
        local prefix = current_content:sub(1, start_idx - 1)
        local suffix = current_content:sub(end_idx + 1)
        
        current_content = prefix .. replace_block .. suffix
        changes_count = changes_count + 1
    end

    if changes_count == 0 then
        -- Если блоков не найдено, возможно LLM просто болтала или формат сбит.
        return false, "No valid SEARCH/REPLACE blocks found in LLM response."
    end

    return true, current_content
end

return M
