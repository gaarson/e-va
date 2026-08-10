
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
# Helper: classify a test file as busted-style or standalone
classify_test() {
  local file="$1"
  if grep -q 'describe(' "$file" 2>/dev/null; then
    echo "busted"
  else
    echo "standalone"
  fi
}
echo ">>> Running tests with coverage..."
OVERALL_STATUS=0
if [ $# -eq 0 ]; then
  # Auto-discover all test files in __tests/ or __tests__/ directories
  TEST_FILES=$(find . -type f -name "*.lua" \( -path "*/__tests/*.lua" -o -path "*/__tests__/*.lua" \) | sort)
  if [ -z "$TEST_FILES" ]; then
    echo ">>> No test files found in __tests/ directories."
    exit 1
  fi
  BUSTED_FILES=""
  STANDALONE_FILES=""
  echo ">>> Discovered test files:"
  echo "$TEST_FILES"
  echo ""
  # Classify each test file
  for f in $TEST_FILES; do
    type=$(classify_test "$f")
    if [ "$type" = "busted" ]; then
      BUSTED_FILES="$BUSTED_FILES $f"
    else
      STANDALONE_FILES="$STANDALONE_FILES $f"
    fi
  done
  # Run busted-style tests
  if [ -n "$BUSTED_FILES" ]; then
    echo ">>> Running busted-style tests:"
    echo "$BUSTED_FILES"
    echo ""
    LUA_INIT="dofile('$PROJECT_ROOT/test_shim.lua')" \
      ./lua_modules/bin/busted --coverage $BUSTED_FILES
    BUSTED_STATUS=$?
    if [ $BUSTED_STATUS -ne 0 ]; then
      OVERALL_STATUS=$BUSTED_STATUS
    fi
    echo ""
  fi
  # Run standalone tests individually
  if [ -n "$STANDALONE_FILES" ]; then
    echo ">>> Running standalone tests:"
    for f in $STANDALONE_FILES; do
      echo "  Running: $f"
      lua "$f"
      STATUS=$?
      if [ $STATUS -ne 0 ]; then
        echo "  FAILED: $f (exit code $STATUS)"
        OVERALL_STATUS=$STATUS
      else
        echo "  PASSED: $f"
      fi
      echo ""
    done
  fi
else
  # Args provided: run each arg according to its type
  for arg in "$@"; do
    if [ -f "$arg" ]; then
      type=$(classify_test "$arg")
      if [ "$type" = "busted" ]; then
        echo ">>> Running busted-style test: $arg"
        LUA_INIT="dofile('$PROJECT_ROOT/test_shim.lua')" \
          ./lua_modules/bin/busted --coverage "$arg"
        STATUS=$?
      else
        echo ">>> Running standalone test: $arg"
        lua "$arg"
        STATUS=$?
      fi
      if [ $STATUS -ne 0 ]; then
        OVERALL_STATUS=$STATUS
      fi
      else
        echo ">>> Running busted with arg: $arg"
        LUA_INIT="dofile('$PROJECT_ROOT/test_shim.lua')" \
          ./lua_modules/bin/busted --pattern='test_.*' --coverage "$arg"
        STATUS=$?
        if [ $STATUS -ne 0 ]; then
        OVERALL_STATUS=$STATUS
      fi
    fi
  done
fi
# Always generate coverage report
echo ">>> Generating coverage report..."
./lua_modules/bin/luacov
echo "========================================="
echo "Coverage Summary:"
grep -E "^/home|^\.e-va|^config|^test_file|^-+$|^Total" luacov.report.out 2>/dev/null || echo "(no coverage data)"
echo "========================================="
exit $OVERALL_STATUS
