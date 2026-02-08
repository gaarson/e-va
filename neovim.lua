-- neovim.lua
-- Модуль для взаимодействия с Neovim через nvr

local M = {}

-- Подключение зависимостей
local utils = require("utils")          -- Ваш модуль утилит
local config_module = require("config") -- Ваш модуль конфигурации
local json = require("JSON")            -- Библиотека для работы с JSON
local string = require("string")
local table = require("table")
local io = require("io")
local os = require("os")
local lfs = require("lfs")         -- Для работы с файловой системой
local patcher = require("patcher") -- Новый модуль для патчинга

--[[
Предполагается, что utils.lua содержит как минимум:
- utils.read_file_content(filepath) -> content, err
- utils.write_file(filepath, content) -> ok, err
- utils.join_path(...) -> path_string
- utils.safe_os_execute(full_cmd) -> output_string, error_message_string (или output, exit_code, error_msg)
- utils.trim_string(str) -> trimmed_string
- utils.split_string(str, separator) -> table_of_strings
- utils.escape_shell_arg(arg_string) -> escaped_arg_string
--]]

--- Получает текущую конфигурацию.
local function get_config()
  return config_module.get()
end

--- Выполняет команду nvr для указанного сервера Neovim.
-- @param server Имя сервера Neovim.
-- @param command Строка команды для nvr (без пути к nvr и --servername).
-- @return string Вывод команды.
-- @return string Сообщение об ошибке, если есть.
function M.nvr_command(server, command)
  local cfg = get_config()
  local full_cmd = string.format('%s --nostart --servername "%s" %s', cfg.NVR_PATH, server, command)
  -- print("DEBUG: Выполнение NVR команды:", full_cmd)
  return utils.safe_os_execute(full_cmd)
end

--- Получает список активных сессий Neovim (серверов nvr).
-- @return table Список имен серверов или пустая таблица.
function M.get_neovim_servers()
  local cfg = get_config()
  local servers_str, err = utils.safe_os_execute(cfg.NVR_PATH .. " --serverlist")
  if not servers_str or #servers_str == 0 then
    print("Предупреждение: Серверы Neovim не найдены или произошла ошибка при получении списка серверов:",
      err or "пустой список")
    return {}
  end
  return utils.split_string(servers_str, "\n")
end

--- Получает информацию о текущих буферах во всех активных сессиях Neovim.
-- @return table Массив таблиц, каждая из которых описывает буфер {server, path, filename, content}.
function M.get_all_vim_buffers()
  local servers = M.get_neovim_servers()
  local result = {}

  for _, server in ipairs(servers) do
    -- Используем json_encode для безопасной передачи данных, содержащих спецсимволы
    local expr_content = "json_encode(join(getline(1, '$'), '\\n'))"
    local expr_filepath = "json_encode(expand('%:p'))"
    local expr_filename = "json_encode(expand('%:t'))"

    -- Выполняем команды для получения данных из Neovim
    local content_json, err_c = M.nvr_command(server, '--remote-expr "' .. expr_content .. '"')
    local filepath_json, err_p = M.nvr_command(server, '--remote-expr "' .. expr_filepath .. '"')
    local filename_json, err_f = M.nvr_command(server, '--remote-expr "' .. expr_filename .. '"')

    if content_json and filepath_json and filename_json then
      local content_str, decode_err_c = json:decode(content_json)
      local filepath_str, decode_err_p = json:decode(filepath_json)
      local filename_str, decode_err_f = json:decode(filename_json)

      if decode_err_c then
        print("Предупреждение: Ошибка декодирования JSON для содержимого на сервере", server,
          decode_err_c)
      end
      if decode_err_p then
        print("Предупреждение: Ошибка декодирования JSON для пути файла на сервере", server,
          decode_err_p)
      end
      if decode_err_f then
        print("Предупреждение: Ошибка декодирования JSON для имени файла на сервере", server,
          decode_err_f)
      end

      if content_str and filepath_str and filename_str then
        table.insert(result, {
          server = server,
          path = utils.trim_string(filepath_str),
          filename = utils.trim_string(filename_str),
          content = content_str -- Содержимое уже является строкой (после join и json_decode)
        })
      else
        print("Предупреждение: Не удалось декодировать JSON ответ от сервера", server,
          "Одна или несколько переменных nil.")
      end
    else
      print("Предупреждение: Не удалось получить информацию о буфере от сервера", server,
        err_c or err_p or err_f or "одна из команд nvr вернула nil")
    end
  end
  return result
end

--- Применяет патч к временному .tmp файлу и инициирует синхронизацию в Neovim.
-- @param server Имя сервера Neovim.
-- @param original_file_path Полный путь к оригинальному файлу в Neovim.
-- @param hunk_content Содержимое патча от LLM (только ханки, начинающиеся с "@@").
-- @return boolean true в случае успеха, false в случае ошибки.
-- @return string Сообщение о результате или ошибке.
function M.apply_patch_to_temp_file_and_sync(server, original_file_path, hunk_content)
  local cfg = get_config()
  local temp_file_to_patch = original_file_path .. ".tmp" -- Патчим временную копию

  -- 1. Прочитать оригинальный файл (или использовать пустой контент, если его нет)
  local original_content, err_read = utils.read_file_content(original_file_path)
  if not original_content then
    if err_read then
      print("Предупреждение: Оригинальный файл '" ..
        original_file_path .. "' не удалось прочитать: " .. err_read .. ". Используется пустой контент для .tmp файла.")
      original_content = "" -- Используем пустой контент, если чтение не удалось
    else
      print("Информация: Оригинальный файл '" ..
        original_file_path .. "' пуст или не существует. Создается .tmp с пустым содержимым.")
      original_content = "" -- Файл пуст или не существует
    end
  end

  -- 2. Подготовка hunk_content
  if hunk_content == nil or type(hunk_content) ~= "string" then
    hunk_content = "" -- Используем пустую строку, если hunk_content некорректен
    print("Предупреждение: hunk_content был nil или не строкой. Используется пустая строка для содержимого патча.")
  end

  -- Очистка hunk_content от лишних пустых строк между ханками, если это необходимо
  hunk_content = utils.trim_string(hunk_content)
  hunk_content = hunk_content:gsub("\n\n+(@@)", "\n%1") -- Удаляет лишние пустые строки перед новым ханком '@@'

  local patch_utils_dependency = {
    safe_os_execute = utils.safe_os_execute,
    write_file = utils.write_file,
    read_file_content = utils.read_file_content,
    join_path = utils.join_path
    -- lfs, os, string, table не нужно передавать, т.к. patcher.lua их сам require'ит
  }


  -- 3. Синхронизация с Neovim (если патч к .tmp успешен)
  -- Команда :SyncTemp (или аналогичная) должна быть определена в конфигурации Neovim пользователя.
  -- Эта команда должна прочитать содержимое temp_file_to_patch и обновить буфер original_file_path.
  -- Оригинальный код использовал nvim_sync_keys, вероятно, для выхода из режима вставки перед командой.
  local nvim_sync_keys = cfg.NVR_SYNC_KEYS or "<Esc>"        -- Получаем из конфига или используем значение по умолчанию
  local command_for_nvim = nvim_sync_keys .. ":SyncTemp<CR>" -- Пользовательская команда Vim

  -- Экранируем всю строку команды для безопасной передачи через shell
  local nvim_remote_send_arg = utils.escape_shell_arg(command_for_nvim)
  local sync_cmd_nvr = string.format(
    '%s --nostart --servername "%s" --remote-send %s',
    cfg.NVR_PATH,
    server,
    nvim_remote_send_arg
  )
  print("Информация: Выполнение команды синхронизации Neovim:", sync_cmd_nvr)
  local sync_success_output, sync_err = utils.safe_os_execute(sync_cmd_nvr)

  if sync_err or (sync_success_output and sync_success_output:match("[Ee]rror")) then
    local err_msg_sync =
        "Предупреждение: Не удалось отправить команду синхронизации или команда сообщила об ошибке для сервера " ..
        server .. "."
    if sync_err then err_msg_sync = err_msg_sync .. " Ошибка выполнения: " .. sync_err end
    if sync_success_output then err_msg_sync = err_msg_sync .. " Вывод: " .. sync_success_output end
    print(err_msg_sync)
    -- Патч применился к .tmp файлу. Решение о фатальности ошибки синхронизации остается за логикой выше.
    -- Важно: если SyncTemp не удаляет .tmp, то он останется.
    -- Для консистентности, если синхронизация не удалась, можно вернуть ошибку, чтобы .tmp был удален ниже.
    -- Однако, оригинальный код продолжал. Чтобы не менять функционал, мы тоже продолжим, но с предупреждением.
  else
    print("Информация: Команда синхронизации Neovim отправлена. Вывод: ", sync_success_output or "N/A")
  end

  -- 4. Вызов patcher.apply_patch для .tmp файла
  -- Формируем таблицу с утилитами для передачи в модуль patcher
  local patch_success, patch_message = patcher.apply_patch(
    temp_file_to_patch,    -- Файл, который патчим (.tmp)
    hunk_content,          -- Содержимое ханка
    cfg.PATCH_COMMAND,     -- Путь к утилите patch из конфигурации
    cfg.TEMP_DIR,          -- Временная директория для файла .patch из конфигурации
    patch_utils_dependency -- Таблица с необходимыми утилитами
  )

  if not patch_success then
    -- Ошибка применения патча, patch_message содержит детали (включая .rej, если был)
    -- .tmp файл может быть в измененном или частично измененном состоянии.
    -- Удаляем .tmp файл в случае ошибки, чтобы не оставить некорректный файл.
    local removed_tmp, err_removed_tmp = os.remove(temp_file_to_patch)
    if not removed_tmp then
      print("Предупреждение: Не удалось очистить временный файл " ..
        temp_file_to_patch .. " после неудачного патча: " .. (err_removed_tmp or "неизвестная ошибка"))
    end
    return false, "Не удалось применить патч к временному файлу '" .. temp_file_to_patch .. "':\n" .. patch_message
  end

  print("Сообщение: " .. patch_message)

  utils.delay(1)
  -- 5. Записать содержимое оригинального файла во временный файл .tmp
  local updated_content, err_read = utils.read_file_content(temp_file_to_patch)
  local ok_write_tmp_initial, err_write_tmp_initial = utils.write_file(temp_file_to_patch, updated_content)

  if not ok_write_tmp_initial then
    return false,
        "Не удалось записать начальное содержимое в .tmp файл '" ..
        temp_file_to_patch .. "': " .. (err_write_tmp_initial or "неизвестная ошибка")
  end
  print("Информация: Создан/обновлен " .. temp_file_to_patch .. " с содержимым из " .. original_file_path)

  -- utils.delay(2)
  -- local removed_tmp, err_removed_tmp = os.remove(temp_file_to_patch)

  -- -- 6. Очистка .tmp файла
  -- if removed_tmp then
  --   print("Информация: Временный файл очищен: " .. temp_file_to_patch)
  -- else
  --   print("Предупреждение: Не удалось очистить временный файл " ..
  --     temp_file_to_patch .. ": " .. (err_removed_tmp or "неизвестная ошибка"))
  --   -- Если .tmp файл не удален, это может быть проблемой.
  --   return false,
  --       "Патч применен к .tmp, команда синхронизации отправлена, но не удалось удалить .tmp файл: " ..
  --       temp_file_to_patch .. ". " .. (err_removed_tmp or "")
  -- end

  return true,
      "Патч успешно применен к временному файлу, команда синхронизации Neovim отправлена для " .. original_file_path
end

return M
