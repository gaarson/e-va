--- patcher.lua
-- Модуль для применения патчей к файлам.

local M = {}

-- Стандартные библиотеки Lua
local io = require("io")
local os = require("os")
local string = require("string")

-- Внешняя зависимость для файловых операций
local lfs = require("lfs")

--[[
Утилиты (utils) должны быть предоставлены вызывающим кодом через параметр `ext_utils`.
Ожидаемые функции в `ext_utils`:
- utils.safe_os_execute(command_string) -> output_string, exit_code (опционально), error_message_string
- utils.write_file(filepath, content) -> boolean_success, error_message_string
- utils.read_file_content(filepath) -> content_string, error_message_string
- utils.join_path(...) -> path_string
--]]
local utils

--- Проверяет валидность содержимого ханка (базовая проверка).
-- @param hunk_content Содержимое ханка.
-- @return boolean true, если валидно, иначе false.
-- @return string Сообщение об ошибке, если не валидно.
local function validate_hunk_content(hunk_content)
  if type(hunk_content) ~= "string" then
    return false, "Содержимое ханка должно быть строкой."
  end
  if not hunk_content:match("^@@") and hunk_content ~= "" then -- Пустой ханк может быть валидным (нет изменений)
    return false, "Содержимое ханка должно начинаться с '@@' или быть пустым."
  end

  -- Проверка каждой строки ханка на соответствие формату diff
  for line in hunk_content:gmatch("[^\r\n]+") do
    -- Строки должны начинаться с '@@', ' ', '+', '-'
    -- Пустые строки между ханками допустимы, если сам hunk_content не пустой
    if not line:match("^@@") and not line:match("^[ %-+].*") then
      if not line:match("^%s*$") then -- Разрешаем полностью пустые строки
        return false, "Недопустимая строка в содержимом ханка: " .. line
      end
    end
  end
  return true
end

--- Применяет патч (hunk) к целевому файлу.
-- @param target_file_path Полный путь к файлу, который нужно запатчить.
-- @param hunk_content Строка, содержащая только ханки diff (например, "@@ -1,1 +1,1 @@ ...").
-- @param patch_executable_path Путь к исполняемому файлу утилиты 'patch'.
-- @param temp_patch_dir Директория для временного хранения файла .patch.
-- @param ext_utils Таблица с необходимыми вспомогательными функциями (safe_os_execute, write_file и т.д.).
-- @return boolean true в случае успеха, false в случае ошибки.
-- @return string Сообщение о результате или ошибке (включая содержимое .rej файла, если применимо).
function M.apply_patch(target_file_path, hunk_content, patch_executable_path, temp_patch_dir, ext_utils)
  utils = ext_utils -- Устанавливаем предоставленные утилиты для использования в этой функции

  -- 1. Валидация входных данных
  local is_valid, validation_msg = validate_hunk_content(hunk_content)
  if not is_valid then
    return false, "Невалидное содержимое ханка: " .. validation_msg
  end

  if not target_file_path or target_file_path == "" then
    return false, "Путь к целевому файлу не может быть пустым."
  end
  if not patch_executable_path or patch_executable_path == "" then
    return false, "Путь к исполняемому файлу patch не может быть пустым."
  end
  if not temp_patch_dir or temp_patch_dir == "" then
    return false, "Директория для временного файла патча не может быть пустой."
  end
  if not utils or not utils.safe_os_execute or not utils.write_file or not utils.read_file_content or not utils.join_path then
    return false, "Таблица внешних утилит (ext_utils) или ее обязательные функции отсутствуют."
  end

  -- Если hunk_content пуст, патч применять не нужно, считаем это успехом (нет изменений).
  if hunk_content == "" then
    print("Info: Hunk content is empty. No patch to apply to " .. target_file_path)
    return true, "Содержимое ханка пустое, патч не применялся."
  end

  -- 2. Подготовка содержимого файла патча
  local target_filename = target_file_path:match("([^/\\]+)$")
  if not target_filename then
    return false, "Не удалось извлечь имя файла из target_file_path: " .. target_file_path
  end

  local diff_header = string.format("--- a/%s\n+++ b/%s\n", target_filename, target_filename)
  local full_patch_data = diff_header .. hunk_content

  -- 3. Создание временной директории для файла .patch, если она не существует
  if lfs.attributes(temp_patch_dir, "mode") ~= "directory" then
    print("Информация: Попытка создать временную директорию для файла .patch:", temp_patch_dir)
    local success_mkdir, err_mkdir = lfs.mkdir(temp_patch_dir)
    if not success_mkdir then
      return false,
          "Не удалось создать временную директорию '" ..
          temp_patch_dir .. "' для файла .patch: " .. (err_mkdir or "неизвестная ошибка")
    end
  end

  full_patch_data = full_patch_data:gsub("%s*$", "") .. "\n"

  full_patch_data = full_patch_data .. "\n"

  local patch_file_on_disk = utils.join_path(temp_patch_dir, "llm_temp_patch_file.patch")
  local ok_write_patch, err_write_patch = utils.write_file(patch_file_on_disk, full_patch_data)

  if not ok_write_patch then
    return false,
        "Не удалось записать файл .patch на диск '" ..
        patch_file_on_disk .. "': " .. (err_write_patch or "неизвестная ошибка")
  end
  print("Информация: Временный файл патча создан: " .. patch_file_on_disk)

  -- 4. Определение директории целевого файла для выполнения команды patch
  local target_file_dir = target_file_path:match("(.*/)") or target_file_path:match("(.*[/\\])")
  if not target_file_dir and target_file_path:match("[^/\\]+") then
    target_file_dir = "./"        -- Файл находится в текущей директории
  elseif not target_file_dir then
    os.remove(patch_file_on_disk) -- Очистка временного файла патча
    return false, "Не удалось определить директорию для целевого файла: " .. target_file_path
  end

  -- 5. Формирование и выполнение команды patch
  -- Используем -u (unified), -p1 (отбросить префикс 'a/' или 'b/'), --forward (пытаться применить уже примененные)
  -- Ключ -i указывает входной файл патча.
  local patch_command_exec_part = string.format('%s --forward -p1 -u -i "%s"', patch_executable_path, patch_file_on_disk)
  print("Информация: Применение патча к '" ..
    target_file_path .. "' в директории '" .. target_file_dir .. "' командой: " .. patch_command_exec_part)

  local full_os_patch_command
  if package.config:sub(1, 1) == '\\' then -- Windows
    local drive = target_file_dir:match("^[a-zA-Z]:")
    full_os_patch_command = (drive and drive .. " && " or "") ..
        string.format('cd /D "%s" && %s', target_file_dir, patch_command_exec_part)
  else -- Unix-like
    full_os_patch_command = string.format('cd "%s" && %s', target_file_dir, patch_command_exec_part)
  end
  print("Информация: Выполнение полной команды ОС для патча: " .. full_os_patch_command)

  -- utils.safe_os_execute должен возвращать: output, exitcode, err_msg
  -- Для простоты, предположим, что он возвращает output (stdout+stderr) и err_msg (если команда не запустилась)
  local patch_output, patch_err_execute = utils.safe_os_execute(full_os_patch_command)

  local final_message = ""
  local success_flag = true

  -- Логика анализа вывода (STRICT MODE)
  if patch_err_execute then
      success_flag = false
      final_message = "Ошибка запуска patch: " .. patch_err_execute
  else
      -- Проверяем вывод на наличие "смертных грехов" патча
      local is_malformed = patch_output:match("malformed") or 
                           patch_output:match("unexpected end") or 
                           patch_output:match("garbage")
                           patch_output:match("missing line number") 
      
      local is_failed = patch_output:match("FAILED") or 
                        patch_output:match("[Rr]eject") or 
                        patch_output:match("saving rejects")

      if is_malformed or is_failed then
          success_flag = false
          final_message = "Патч ОТКЛОНЕН (Malformed/Rejected).\nВывод команды patch:\n" .. (patch_output or "")
      
      elseif patch_output and patch_output:match("patching file") then
          -- Только если нет ошибок И есть подтверждение "patching file"
          success_flag = true
          final_message = "Патч успешно применен.\nВывод:\n" .. patch_output
          
      elseif patch_output == nil or patch_output:match("^%s*$") then
          -- Некоторые версии patch молчат при успехе (редко, но бывает)
          success_flag = true 
          final_message = "Вывод пуст (предполагается успех)."
      else
          -- Непонятный вывод
          success_flag = false
          final_message = "Неясный статус патча. Проверьте вручную.\nВывод:\n" .. (patch_output or "")
      end
  end

  -- 6. Обработка файла .rej в случае ошибки
  if not success_flag then
    local reject_file_path = utils.join_path(target_file_dir, target_filename .. ".rej")
    print("Информация: Проверка наличия файла .rej по пути: " .. reject_file_path)
    if lfs.attributes(reject_file_path, "mode") == "file" then
      local rej_content, err_read_rej = utils.read_file_content(reject_file_path)
      if rej_content then
        final_message = final_message ..
            "\n\n--- Содержимое файла .rej (" .. reject_file_path .. "): ---\n" .. rej_content
      else
        final_message = final_message .. "\n\n--- Не удалось прочитать файл .rej (" .. reject_file_path .. ")" ..
            (err_read_rej and (": " .. err_read_rej) or "") .. " ---"
      end
      local removed_rej, err_remove_rej = os.remove(reject_file_path)
      if not removed_rej then
        print("Предупреждение: Не удалось удалить файл .rej " ..
          reject_file_path .. (err_remove_rej and (": " .. err_remove_rej) or ""))
        final_message = final_message .. "\nПредупреждение: Не удалось удалить файл .rej: " .. reject_file_path
      else
        print("Информация: Файл .rej удален: " .. reject_file_path)
      end
    else
      print("Информация: Файл .rej не найден по пути: " .. reject_file_path)
      final_message = final_message .. "\nФайл .rej не найден в ожидаемом месте (" .. reject_file_path .. ")."
    end
  end

  -- 7. Обработка файла .orig (удаляем в любом случае, если он создан)
  local orig_file_path = utils.join_path(target_file_dir, target_filename .. ".orig")
  if lfs.attributes(orig_file_path, "mode") == "file" then
    local removed_orig, err_remove_orig = os.remove(orig_file_path)
    if not removed_orig then
      print("Предупреждение: Не удалось удалить файл .orig " ..
        orig_file_path .. (err_remove_orig and (": " .. err_remove_orig) or ""))
    else
      print("Информация: Файл .orig удален: " .. orig_file_path)
    end
  end

  -- 8. Очистка временного файла .patch
  if patch_file_on_disk and lfs.attributes(patch_file_on_disk, "mode") == "file" then
    local removed_patch_tmp, err_remove_patch_tmp = os.remove(patch_file_on_disk)
    if not removed_patch_tmp then
      print("Предупреждение: Не удалось удалить временный файл .patch " ..
        patch_file_on_disk .. (err_remove_patch_tmp and (": " .. err_remove_patch_tmp) or ""))
    else
      print("Информация: Временный файл .patch удален: " .. patch_file_on_disk)
    end
  end

  return success_flag, final_message
end

return M
