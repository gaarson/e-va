
#!/bin/bash
PROJECT_ROOT="$(pwd)"
# Load .env file if it exists (parse KEY=VALUE lines and export them)
if [ -f "$PROJECT_ROOT/.env" ]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines (POSIX-compatible)
        case "$key" in
            ''|\#*) continue ;;
        esac
        # Trim whitespace
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Skip if key is empty after trimming
        [ -z "$key" ] && continue
        # Remove surrounding quotes from value
        value=$(echo "$value" | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//')
        export "$key=$value"
    done < "$PROJECT_ROOT/.env"
    echo ">>> Loaded .env file"
fi
# Default test environment variables (override with real ones if set)
export LLM_API_KEY="${LLM_API_KEY:-test_api_key_placeholder}"
export LLM_BASE_URL="${LLM_BASE_URL:-http://localhost:8000/v1/chat/completions}"
export LLM_MODEL="${LLM_MODEL:-test-model}"
LUA_VERSION=$(lua -v 2>&1 | awk '{print $2}' | cut -d. -f1,2)
# Include all subdirectory modules so tests in __tests__ subdirs can require() parent modules
export LUA_PATH="$PROJECT_ROOT/?.lua;$PROJECT_ROOT/?/init.lua;$PROJECT_ROOT/tools/?.lua;$PROJECT_ROOT/tools/?/init.lua;$PROJECT_ROOT/agent/?.lua;$PROJECT_ROOT/agent/?/init.lua;$PROJECT_ROOT/context_compressor/?.lua;$PROJECT_ROOT/context_compressor/?/init.lua;$PROJECT_ROOT/utils/?.lua;$PROJECT_ROOT/utils/?/init.lua;$PROJECT_ROOT/multi_stage_executor/?.lua;$PROJECT_ROOT/multi_stage_executor/?/init.lua;$PROJECT_ROOT/patcher/?.lua;$PROJECT_ROOT/patcher/?/init.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?.lua;$PROJECT_ROOT/lua_modules/share/lua/${LUA_VERSION}/?/init.lua;;"
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
    ./lua_modules/bin/busted --pattern='test_.*' --coverage "$@"
fi

TEST_STATUS=$?


if [ $TEST_STATUS -eq 0 ]; then
    echo ">>> Generating coverage report..."
    ./lua_modules/bin/luacov

    echo "========================================="

    echo "Coverage Summary:"
    grep -E "^/home|^\.e-va|^config|^test_file|^-+$|^Total" luacov.report.out
    echo "========================================="
else
    echo ">>> Tests failed. Skipping coverage report."
fi


exit $TEST_STATUS