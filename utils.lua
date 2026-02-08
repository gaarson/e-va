-- utils.lua
local M = {}
local io = require("io")

function M.read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    local ok, w_err = f:write(content)
    f:close()
    if not ok then return false, w_err end
    return true
end

function M.trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function M.list_files_recursive(root_path)
    local output = ""
    local method = "unknown"

    -- 1. Попытка использовать ripgrep (rg)
    -- --files: только список файлов
    -- --color never: без ANSI кодов
    -- 2>/dev/null: прячем ошибки если rg не установлен
    local cmd_rg = string.format("cd '%s' && rg --files --color never 2>/dev/null", root_path)
    local p_rg = io.popen(cmd_rg)
    if p_rg then
        local out = p_rg:read("*a")
        p_rg:close()
        if out and out ~= "" then
            output = out
            method = "ripgrep"
        end
    end

    -- 2. Если rg не сработал, пробуем git
    if method == "unknown" then
        -- --cached: файлы под контролем git
        -- --others: новые (untracked) файлы
        -- --exclude-standard: применять правила .gitignore к новым файлам
        local cmd_git = string.format("git -C '%s' ls-files --cached --others --exclude-standard 2>/dev/null", root_path)
        local p_git = io.popen(cmd_git)
        if p_git then
            local out = p_git:read("*a")
            p_git:close()
            if out and out ~= "" then
                output = out
                method = "git"
            end
        end
    end

    -- 3. Fallback: старый добрый find (если нет ни rg, ни git)
    if method == "unknown" then
        local cmd_find = string.format("find '%s' -type f -not -path '*/.*' -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/target/*' -not -path '*/vendor/*'", root_path)
        local p_find = io.popen(cmd_find)
        if p_find then
            output = p_find:read("*a")
            p_find:close()
            
            -- Find возвращает полные пути (./file), чистим их
            local clean_output = {}
            for line in output:gmatch("[^\r\n]+") do
                -- Убираем префикс root_path если он есть
                local rel_path = line
                if line:sub(1, #root_path) == root_path then
                     rel_path = line:sub(#root_path + 2)
                elseif line:sub(1, 2) == "./" then
                     rel_path = line:sub(3)
                end
                table.insert(clean_output, rel_path)
            end
            output = table.concat(clean_output, "\n")
            method = "find"
        end
    end

    -- SAFETY: Защита от переполнения контекста
    -- Если файлов слишком много (например > 200), мы обрезаем список, 
    -- иначе LLM сойдет с ума и забудет задачу.
    local file_list = {}
    local count = 0
    local limit = 200 -- Лимит файлов для отображения
    
    for line in output:gmatch("[^\r\n]+") do
        count = count + 1
        if count <= limit then
            table.insert(file_list, line)
        end
    end
    
    local result = table.concat(file_list, "\n")
    
    if count > limit then
        result = result .. "\n\n... [TRUNCATED: Showing " .. limit .. " of " .. count .. " files. Use search to find specific files.]"
    end
    
    if result == "" then
        return "(No files found or empty directory)"
    end

    return result
end

function M.search_project(root_path, pattern)
    -- Экранируем двойные кавычки, чтобы не сломать bash-команду
    local safe_pattern = pattern:gsub('"', '\\"')
    
    -- Флаги ripgrep для LLM:
    -- -n (line-number): выводить номера строк (критично для патчей)
    -- -C 2 (context): показывать 2 строки до и после совпадения
    -- --color never: отключить ANSI-цвета (они мусорят в контексте LLM)
    -- --no-heading: формат вывода "файл:строка:код" вместо группировки (легче читать машине)
    -- --smart-case: если паттерн с маленькой буквы - нечувствителен к регистру, если есть заглавные - чувствителен
    -- -e: явно указывает, что дальше идет паттерн (безопасно для паттернов начинающихся с -)
    local cmd = string.format("rg -n -C 2 --color never --no-heading --smart-case -e \"%s\" \"%s\"", safe_pattern, root_path)
    
    local p = io.popen(cmd)
    if not p then return "Error: Could not execute rg (ripgrep). Is it installed?" end
    
    local output = p:read("*a")
    p:close()
    
    if not output or output == "" then
        return "No matches found for pattern: " .. pattern
    end
    
    -- Защита от переполнения контекста (Token Limit Protection)
    -- Ограничиваем вывод ~8000 байт (это примерно 2-3k токенов)
    local max_bytes = 8000
    if #output > max_bytes then
        return output:sub(1, max_bytes) .. "\n\n... [OUTPUT TRUNCATED: Too many matches (" .. #output .. " bytes). Please refine your search query (make it more specific).]"
    end
    
    return output
end

function M.run_shell_cmd(cmd)
    local p = io.popen(cmd .. " 2>&1")
    if not p then return "Error: Failed to launch command" end
    
    local output = p:read("*a")
    
    -- Получаем возвращаемые значения. В Lua 5.1 это только (ok). В 5.3 (ok, type, code)
    local ret1, ret2, ret3 = p:close()
    
    local exit_info = "0"
    
    if type(ret3) == "number" then
        -- Lua 5.2+ behavior: ret3 is the exit code
        exit_info = tostring(ret3)
    elseif ret1 == nil then
        -- Lua 5.1 behavior: process failed
        exit_info = "NON-ZERO (Unknown code in Lua 5.1)"
    elseif ret1 == true then
        -- Lua 5.1 behavior: process success
        exit_info = "0"
    end
    
    -- Используем %s, так как exit_info теперь всегда строка
    return string.format("EXIT STATUS: %s\nOUTPUT:\n%s", exit_info, output)
end

return M
