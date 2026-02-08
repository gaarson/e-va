-- config.lua
-- Модуль для загрузки конфигурации из .env файла

local M = {}

local io_lib = require("io")       -- Используем другое имя, чтобы не конфликтовать с io таблицей если она есть глобально
local os = require("os")
local lfs = require("lfs")         -- Requires LuaFileSystem
local utils = require("utils")     -- Assuming utils.lua is in the same directory or package.path
local inspect = require("inspect") -- Для отладки

local loaded_config = nil

--- Загружает конфигурацию из файла .env.
-- Поддерживает многострочные значения в формате:
-- MY_VAR="
-- Это первая строка значения.
-- Это вторая строка, она может содержать " кавычки ".
-- "
-- Многострочное значение начинается с KEY=" (и больше ничего на строке)
-- и заканчивается строкой, содержащей только " (после обрезки пробелов).
-- Комментарии (#) игнорируются вне многострочных значений.
-- Если новая переменная (KEY=VALUE) начинается до закрывающей кавычки ",
-- текущее многострочное значение завершается и новая переменная обрабатывается.
function M.load(env_path)
  if loaded_config then return loaded_config end

  env_path = env_path or os.getenv("ENV_PATH") or ".env"
  
  local root = os.getenv("PROJECT_ROOT")
  if root and not env_path:match("^/") then
      env_path = root .. "/" .. env_path
  end

  env_path = env_path or ".env"
  local cfg = {}
  local file, err_open = io_lib.open(env_path, "r")

  if not file then
    print("Warning: Could not open config file " .. env_path .. ". Using defaults. Error: " .. (err_open or "unknown"))
  else
    local lines = {}
    for l in file:lines() do
      table.insert(lines, l)
    end
    file:close()

    local i = 1
    local current_multiline_key = nil
    local current_multiline_value_parts = {}

    while i <= #lines do
      local original_line = lines[i]

      if current_multiline_key then
        -- Мы находимся в режиме чтения многострочного значения
        local trimmed_original_line = utils.trim_string(original_line)

        -- Проверяем, является ли текущая строка началом нового объявления переменной
        local is_new_key_def = false
        -- Сначала удаляем комментарий (если есть) и обрезаем пробелы для проверки
        local line_for_new_var_check = utils.trim_string(original_line:gsub("#.*", ""))
        if #line_for_new_var_check > 0 then
          local pk, pv = line_for_new_var_check:match("([^=]+)=(.*)")
          if pk and pv then -- Строка соответствует формату KEY=VALUE
            is_new_key_def = true
          end
        end

        if trimmed_original_line == '"' then
          -- Это закрывающая кавычка для многострочного значения
          cfg[current_multiline_key] = table.concat(current_multiline_value_parts, "\n")
          current_multiline_key = nil
          current_multiline_value_parts = {}
          i = i + 1 -- Переходим к следующей строке
        elseif is_new_key_def then
          -- Новое объявление переменной найдено до закрывающей кавычки "
          print("Warning: New variable definition on line '" ..
            original_line ..
            "' encountered before multi-line value for key '" ..
            current_multiline_key ..
            "' was properly closed by '\"'. Assigning accumulated content for '" .. current_multiline_key .. "'.")
          cfg[current_multiline_key] = table.concat(current_multiline_value_parts, "\n")
          current_multiline_key = nil
          current_multiline_value_parts = {}
          -- НЕ увеличиваем i, чтобы текущая строка была обработана заново как новое объявление
        else
          -- Это часть многострочного значения, добавляем строку как есть
          table.insert(current_multiline_value_parts, original_line)
          i = i + 1 -- Переходим к следующей строке
        end
      else
        -- Обычный режим: ищем новые переменные
        -- Удаляем комментарии и обрезаем пробелы
        local line_for_parsing = utils.trim_string(original_line:gsub("#.*", ""))

        if #line_for_parsing > 0 then
          local k, v = line_for_parsing:match("([^=]+)=(.*)")
          if k and v then
            k = utils.trim_string(k)
            local trimmed_v = utils.trim_string(v)

            if trimmed_v == '"' then
              -- Начало многострочного значения (например, MY_KEY=")
              current_multiline_key = k
              current_multiline_value_parts = {} -- Очищаем для нового значения
            else
              -- Обычное однострочное значение
              -- Удаляем необязательные обрамляющие кавычки (двойные или одинарные)
              trimmed_v = trimmed_v:match('^["\']?(.*?)["\']?$') or trimmed_v
              cfg[k] = trimmed_v
            end
            -- else: строка не пустая, не комментарий, но не в формате KEY=VALUE - игнорируем
          end
        end
        i = i + 1 -- Переходим к следующей строке
      end
    end

    -- Если файл закончился, а мы все еще в режиме многострочного значения
    if current_multiline_key then
      print("Warning: EOF reached while parsing multi-line value for key '" ..
        current_multiline_key .. "'. Assigning accumulated content.")
      cfg[current_multiline_key] = table.concat(current_multiline_value_parts, "\n")
    end
  end

  -- Значения по умолчанию
  cfg.PROJECT_ROOT = cfg.PROJECT_ROOT or os.getenv("PWD") or (lfs and lfs.currentdir and lfs.currentdir()) or "."

  cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or cfg.PROJECT_ROOT or lfs.currentdir()

  cfg.NVR_PATH = cfg.NVR_PATH or "nvr" -- Default to nvr in PATH
  cfg.API_URL = cfg.API_URL or "http://192.168.0.116:5000/v1/chat/completions"
  cfg.API_MODEL = cfg.API_MODEL or "code_chunk_editor"
  cfg.TEMP_DIR = cfg.TEMP_DIR or os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"
  cfg.PATCH_COMMAND = cfg.PATCH_COMMAND or "patch"
  cfg.SYSTEM_PROMPT = cfg.SYSTEM_PROMPT or [[You are a silent code refactoring engine. 
Output ONLY the Unified Diff format (starting with '@@').
RULES:
1. Start with the Hunk Header. Example: @@ -1,5 +1,5 @@
2. Context lines start with space.
3. Removed lines start with '-'.
4. Added lines start with '+'.
NO comments, NO explanations.
]]

  print(inspect(cfg)) -- Раскомментируйте для отладки загруженной конфигурации
  loaded_config = cfg
  return cfg
end

--- Получает текущую конфигурацию (загружает, если еще не загружена).
function M.get()
  if not loaded_config then
    return M.load()
  end
  return loaded_config
end

return M
