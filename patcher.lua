-- patcher.lua
local M = {}

-- Разбивает строку на массив строк
local function split_lines(text)
    local lines = {}
    for line in text:gmatch("([^\r\n]*)\r?\n?") do
        table.insert(lines, line)
    end
    -- gmatch иногда создает пустую строку в конце, убираем
    if lines[#lines] == "" then table.remove(lines) end
    return lines
end

-- Сравнивает две строки, игнорируя начальные/конечные пробелы
local function fuzzy_match_line(line_a, line_b)
    if not line_a or not line_b then return false end
    return line_a:gsub("^%s+", ""):gsub("%s+$", "") == line_b:gsub("^%s+", ""):gsub("%s+$", "")
end

function M.apply_search_replace(original_content, llm_response)
    if not original_content or not llm_response then
        return false, "Invalid input"
    end

    local file_lines = split_lines(original_content)
    local changes_made = 0
    local has_blocks = false

    -- Парсим блоки SEARCH/REPLACE
    for search_block, replace_block in llm_response:gmatch("<<<<<<< SEARCH\n(.-)\n=======\n(.-)\n>>>>>>> REPLACE") do
        has_blocks = true
        
        -- === IDEMPOTENCY CHECK (LUA 5.1 STYLE) ===
        -- Если блок поиска не равен блоку замены, выполняем логику.
        -- Если равен - просто пропускаем (ничего не делаем).
        if search_block ~= replace_block then
            
            local search_lines = split_lines(search_block)
            local match_found = false
            local start_idx = -1

            -- 1. Ищем блок (Line-by-Line fuzzy search)
            for i = 1, #file_lines - #search_lines + 1 do
                local match = true
                for j = 1, #search_lines do
                    if not fuzzy_match_line(file_lines[i + j - 1], search_lines[j]) then
                        match = false
                        break
                    end
                end

                if match then
                    start_idx = i
                    match_found = true
                    break 
                end
            end

            if not match_found then
                -- Прерываем цикл и возвращаем ошибку сразу
                return false, "CRITICAL: SEARCH block not found.\nLooking for:\n" .. (search_lines[1] or "???")
            end

            -- 2. Применяем замену
            -- Удаляем старые строки
            for _ = 1, #search_lines do
                table.remove(file_lines, start_idx)
            end

            -- Вставляем новые строки
            local replace_lines = split_lines(replace_block)
            for j = #replace_lines, 1, -1 do
                table.insert(file_lines, start_idx, replace_lines[j])
            end

            changes_made = changes_made + 1
        end
    end

    -- Логика завершения
    if changes_made == 0 then
        -- Если блоки были (has_blocks = true), но changes_made = 0,
        -- значит все патчи были "холостыми" (search == replace).
        -- Считаем это успехом, но возвращаем 0 изменений.
        if has_blocks then
             return true, original_content, 0
        end
        return false, "No valid SEARCH/REPLACE blocks found."
    end

    return true, table.concat(file_lines, "\n"), changes_made
end

return M
