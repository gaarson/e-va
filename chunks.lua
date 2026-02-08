-- Модуль text_chunker
local M = {}

-- Функция для разделения текста на строки
local function split_into_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

-- Функция для разделения текста на чанки
function M.split_into_chunks(file_content, chunk_size)
    local function create_chunk(lines, start, last)
        local chunk_lines = {}
        for i = start, last do
            if lines[i] then
                table.insert(chunk_lines, i .. "-:" .. lines[i])
            end
        end
        return table.concat(chunk_lines, "\n")
    end

    local lines = split_into_lines(file_content)
    local chunks = {}
    local num_lines = #lines
    local num_chunks = math.ceil(num_lines / chunk_size)

    for i = 1, num_chunks do
        local start = (i - 1) * chunk_size + 1
        local last = math.min(i * chunk_size, num_lines)
        local chunk = create_chunk(lines, start, last)
        table.insert(chunks, chunk)
    end

    return chunks
end

-- Функция для объединения чанков в полный текст
function M.merge_chunks(chunks)
    local lines = {}
    local max_number = 0

    for _, chunk in ipairs(chunks) do
        local chunk_lines = split_into_lines(chunk)
        for _, line in ipairs(chunk_lines) do
            local number, text = line:match("^(%d+)%-:(.*)$")
            if number then
                number = tonumber(number)
                lines[number] = text
                if number > max_number then
                    max_number = number
                end
            end
        end
    end

    local full_text = {}
    for i = 1, max_number do
        if lines[i] then
            table.insert(full_text, lines[i])
        else
            table.insert(full_text, "")
        end
    end

    return table.concat(full_text, "\n")
end

-- Обновленная функция для сравнения двух чанков с приведением к общему виду
function M.compare_chunks(chunk1, chunk2)
    -- Если чанки идентичны как строки, сразу возвращаем true
    if chunk1 == chunk2 then
        return true
    end

    -- Разделяем чанки на строки
    local lines1 = split_into_lines(chunk1)
    local lines2 = split_into_lines(chunk2)

    -- Проверяем, совпадает ли количество строк
    if #lines1 ~= #lines2 then
        return false
    end

    -- Сравниваем строки построчно, игнорируя ведущие пробелы
    for i = 1, #lines1 do
        -- Извлекаем номер и текст, игнорируя пробелы перед номером
        local num1, text1 = lines1[i]:match("^%s*(%d+)%-:(.*)$")
        local num2, text2 = lines2[i]:match("^%s*(%d+)%-:(.*)$")

        -- Проверяем, что обе строки валидны и имеют ожидаемый формат
        if not (num1 and num2) then
            return false
        end

        -- Преобразуем номера в числа для сравнения
        num1 = tonumber(num1)
        num2 = tonumber(num2)

        -- Сравниваем номера строк и текст
        if num1 ~= num2 or text1 ~= text2 then
            return false
        end
    end

    return true
end

return M

