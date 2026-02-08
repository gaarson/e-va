-- utils.lua
-- Модуль с общими вспомогательными функциями

local M = {}

local io = require("io")
local os = require("os")
local string = require("string")
local table = require("table")

--- Безопасное выполнение команды ОС и получение вывода.
function M.safe_os_execute(cmd)
  -- Перенаправляем stderr в stdout, чтобы захватить все сообщения
  local cmd_with_stderr_redirect = cmd .. " 2>&1"

  -- Для отладки можно вывести команду, которая будет выполнена
  -- print("Executing command with stderr redirect:", cmd_with_stderr_redirect)

  local pipe = io.popen(cmd_with_stderr_redirect, "r")
  if not pipe then
    return nil, "Failed to open pipe for command: " .. cmd_with_stderr_redirect
  end

  local output = pipe:read("*a")
  -- print('DEBUG safe_os_execute OUTPUT CAPTURED:', output) -- Для отладки захваченного вывода

  local ok, status, code = pipe:close()

  -- Обработка вывода: убираем последний перевод строки, если он есть,
  -- и гарантируем, что возвращаем пустую строку вместо nil, если вывода не было.
  local processed_output = (output or "")
  if processed_output ~= "" then
    processed_output = processed_output:gsub("\n$", "") -- Удалить один перевод строки в конце, если есть
  end

  if not ok then
    -- Команда завершилась с ошибкой (например, ненулевой код выхода)
    -- status может быть 'exit', 'signal'
    -- code это код выхода или номер сигнала
    local err_msg = "Command failed. Status: " .. tostring(status) .. ", Code: " .. tostring(code)
    print("Error in safe_os_execute for command '" .. cmd .. "': " .. err_msg)
    print("Command output (if any):\n" .. processed_output)
    return processed_output, err_msg -- Возвращаем вывод и сообщение об ошибке
  end

  -- Команда успешно выполнена (код выхода 0)
  return processed_output -- Возвращаем только вывод
end

--- Разделяет строку по разделителю.
function M.split_string(inputstr, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = {}
  if inputstr and #inputstr > 0 then
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
      table.insert(t, str)
    end
  end
  return t
end

--- Удаляет пробелы в начале и конце строки.
function M.trim_string(text)
  if not text then return "" end
  return text:match("^%s*(.-)%s*$")
end

--- Записывает данные в файл.
function M.write_file(filename, data)
  local file, err = io.open(filename, "w")
  if not file then
    return false, "Failed to open file for writing: " .. filename .. " (" .. (err or "unknown error") .. ")"
  end
  local ok, write_err = file:write(data)
  if not ok then
    file:close()
    return false, "Failed to write to file: " .. filename .. " (" .. (write_err or "unknown error") .. ")"
  end
  file:close()
  return true
end

--- Читает содержимое файла.
function M.read_file(filename)
  local file, err = io.open(filename, "r")
  if not file then
    return nil, "Failed to open file for reading: " .. filename .. " (" .. (err or "unknown error") .. ")"
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.read_file_content(filepath)
  local file, err_open = io.open(filepath, "r")
  if not file then
    return nil, "Failed to open file '" .. filepath .. "' for reading: " .. (err_open or "unknown")
  end
  local content, err_read = file:read("*a")
  file:close()
  if err_read then -- Ошибка при чтении (не EOF)
    return nil, "Error reading file '" .. filepath .. "': " .. err_read
  end
  return content -- Может быть nil если файл пуст и read("*a") вернул nil без ошибки
end

--- Получает расширение файла из имени.
function M.get_file_extension(filename)
  return filename:match("%.([^.]+)$") or ""
end

--- Объединяет базовый путь и относительный путь.
function M.join_path(base_path, relative_path)
  if not base_path or not relative_path then return nil end
  base_path = base_path:gsub("\\", "/")
  relative_path = relative_path:gsub("\\", "/")

  if base_path:sub(-1) == "/" then
    base_path = base_path:sub(1, -2)
  end
  if relative_path:sub(1, 1) == "/" then
    relative_path = relative_path:sub(2, -1)
  end

  while relative_path:match("^%.%./") do
    local parent_path = base_path:match("(.*/)")
    if not parent_path then return nil end -- Cannot go above root
    base_path = parent_path:sub(1, -2)
    relative_path = relative_path:sub(4)
  end

  relative_path = relative_path:gsub("^%.%/", "")

  if #relative_path == 0 then
    return base_path
  end
  if #base_path == 0 then
    return relative_path
  else
    return base_path .. "/" .. relative_path
  end
end

function M.escape_shell_arg(arg)
  if not arg then return "" end
  if package.config:sub(1, 1) ~= '\\' then -- Не Windows
    return "'" .. arg:gsub("'", "'\\''") .. "'"
  else                                     -- Windows (очень упрощенно)
    return '"' .. arg .. '"'
  end
end

function M.delay(seconds)
  local startTime = os.clock()
  while os.clock() - startTime < seconds do
    -- Эта петля будет активно работать, ничего не делая,
    -- пока не истечет заданное время.
  end
end

return M
