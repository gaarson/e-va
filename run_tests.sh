#!/bin/bash
PROJECT_ROOT="$(pwd)"
LUA_VERSION=$(lua -v 2>&1 | awk '{print $2}' | cut -d. -f1,2)

export LUA_PATH="$PROJECT_ROOT/?.lua;$PROJECT_ROOT/?/init.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?/init.lua;;"
export LUA_CPATH="$PROJECT_ROOT/?.so;$PROJECT_ROOT/lua_modules/lib/lua/${LUA_VERSION}/?.so;;"

echo ">>> Running tests with coverage..."
if [ $# -eq 0 ]; then
    # Auto-discover all __tests/ or __tests__/ directories
    TEST_DIRS=$(find . -type d \( -name "__tests" -o -name "__tests__" \) | sort)
    if [ -z "$TEST_DIRS" ]; then
        echo ">>> No __tests/ directories found."
        exit 1
    fi
    echo ">>> Discovered test directories:"
    echo "$TEST_DIRS"
    ./lua_modules/bin/busted --coverage $TEST_DIRS
else
    ./lua_modules/bin/busted --coverage "$@"
fi
TEST_STATUS=$?

if [ $TEST_STATUS -eq 0 ]; then
    echo ">>> Generating coverage report..."
    ./lua_modules/bin/luacov

    echo "========================================="
    echo "Coverage Summary:"
    tail -n 10 luacov.report.out
    echo "========================================="
else
    echo ">>> Tests failed. Skipping coverage report."
fi

exit $TEST_STATUS