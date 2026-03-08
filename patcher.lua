local M = {}
-- Подключаем наш высокопроизводительный C-backend
local patcher_core = require("patcher_core")

local function to_lines(str)
    local t = {}
    local clean = str:gsub("\r\n", "\n"):gsub("\r", "\n")

    for line in clean:gmatch("([^\n]*)\n?") do
        table.insert(t, line)
    end

    if #t > 0 and t[#t] == "" then
        table.remove(t)
    end
    return t
end

function M.apply_patch(original_content, llm_response)
    if not original_content then return false, "No content provided" end

    local content = original_content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local response = llm_response:gsub("\r\n", "\n"):gsub("\r", "\n")

    local changes_count = 0
    local errors = {}

    local file_lines = to_lines(content)

    for search_block, replace_block in response:gmatch("<<<<<<< SEARCH%s*\n(.-)\n=======[^\n]*\n(.-)\n>>>>>>>[^\n]*") do

        local search_lines = to_lines(search_block)
        local replace_lines = to_lines(replace_block)

        -- Проверяем, есть ли вообще печатные символы в блоке поиска
        local has_content = false
        for _, l in ipairs(search_lines) do
            if l:match("%S") then has_content = true; break end
        end

        if has_content then
            -- Вызов нативного C-модуля (Zero-Allocation Search)
            local s_line, e_line, err_msg = patcher_core.find_unique_fuzzy_block(file_lines, search_lines)

            if s_line and e_line then
                -- Удаляем старые строки
                local count_to_remove = e_line - s_line + 1
                for _ = 1, count_to_remove do
                    table.remove(file_lines, s_line)
                end

                -- Вставляем новые строки
                for i = #replace_lines, 1, -1 do
                    table.insert(file_lines, s_line, replace_lines[i])
                end

                changes_count = changes_count + 1
            else
                local snippet = search_block:sub(1, 100):gsub("\n", " ")
                if #snippet > 50 then snippet = snippet:sub(1,50) .. "..." end

                local reason = err_msg or "Fuzzy failed in C module"
                table.insert(errors, string.format("FAILED BLOCK: '%s' -> %s", snippet, reason))
            end
        end
    end

    if changes_count > 0 then
        return true, table.concat(file_lines, "\n"), changes_count
    else
        if #errors > 0 then
            return false, "Patch Failed:\n" .. table.concat(errors, "\n")
        else
            return false, "No valid SEARCH/REPLACE blocks found. Ensure format:\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE"
        end
    end
end

return M
