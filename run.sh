#!/bin/bash

# --- 1. Определяем "Ground Truth" (Корневую директорию) ---
# Эта команда получает абсолютный путь к папке, где лежит этот скрипт,
# даже если он вызван через симлинк или из другой директории.
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Экспортируем переменную, чтобы Lua-скрипт (и subprocesses) её видели
export PROJECT_ROOT
# Также явно укажем путь к конфигу
export ENV_PATH="$PROJECT_ROOT/.env"

# --- 2. Настройка путей Lua (Dependency Resolution) ---
# Находим версию Lua (например, 5.1 или 5.3)
LUA_VERSION=$(lua -v 2>&1 | awk '{print $2}' | cut -d. -f1,2)

# Формируем пути для require().
# Важно: Мы используем $PROJECT_ROOT, а не относительный "./"
export LUA_PATH="$PROJECT_ROOT/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?/init.lua;;"
export LUA_CPATH="$PROJECT_ROOT/lua_modules/lib/lua/${LUA_VERSION}/?.so;;"

# --- 3. Запуск Агента ---
# Передаем управление в Lua. "$@" передает все аргументы (имя файла, инструкцию)
exec lua "$PROJECT_ROOT/agent.lua" "$@"
