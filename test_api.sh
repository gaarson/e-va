#!/bin/bash

SOURCE="${BASH_SOURCE}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
PROJECT_ROOT="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

export PROJECT_ROOT

LUA_VERSION=$(lua -v 2>&1 | awk '{print $2}' | cut -d. -f1,2)

# Подгружаем пути, включая .e-va-conf для локальных конфигов
export LUA_PATH="$PROJECT_ROOT/.e-va-conf/?.lua;$PROJECT_ROOT/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?/init.lua;;"
export LUA_CPATH="$PROJECT_ROOT/?.so;$PROJECT_ROOT/lua_modules/lib/lua/${LUA_VERSION}/?.so;;"

lua "$PROJECT_ROOT/api_tester.lua" "$1"
