#!/bin/bash
PROJECT_ROOT="$(pwd)"
LUA_VERSION=$(lua -v 2>&1 | awk '{print $2}' | cut -d. -f1,2)

export LUA_PATH="$PROJECT_ROOT/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?/init.lua;;"
export LUA_CPATH="$PROJECT_ROOT/lua_modules/lib/lua/${LUA_VERSION}/?.so;;"

./lua_modules/bin/busted "$@"
