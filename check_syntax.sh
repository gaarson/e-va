#!/bin/bash


PROJECT_ROOT="$(pwd)"


LUA_VERSION=$(lua -v 2>&1 | awk '{print $2}' | cut -d. -f1,2)


export LUA_PATH="$PROJECT_ROOT/?.lua;$PROJECT_ROOT/?/init.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?/init.lua;;"

export LUA_CPATH="$PROJECT_ROOT/?.so;$PROJECT_ROOT/lua_modules/lib/lua/${LUA_VERSION}/?.so;;"


echo ">>> Checking Lua syntax for all .lua files..."


LUA_FILES=$(find . -type f -name "*.lua" -not -path "./lua_modules/*" -not -path "./.git/*" | sort)


if [ -z "$LUA_FILES" ]; then

    echo ">>> No .lua files found."

    exit 1

fi


ERROR_COUNT=0

FILE_COUNT=0


while IFS= read -r file; do

    FILE_COUNT=$((FILE_COUNT + 1))

    if ! luac -p "$file" 2>&1; then

        ERROR_COUNT=$((ERROR_COUNT + 1))

        echo ">>> SYNTAX ERROR in: $file"

    fi

done <<< "$LUA_FILES"


echo ""

echo "========================================="

echo "Syntax Check Summary:"

echo "  Files checked: $FILE_COUNT"

echo "  Errors found:  $ERROR_COUNT"

echo "========================================="


if [ $ERROR_COUNT -gt 0 ]; then

    echo ">>> Syntax check FAILED."

    exit 1

else

    echo ">>> All files passed syntax check."

    exit 0

fi