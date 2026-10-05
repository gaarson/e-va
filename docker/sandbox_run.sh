#!/bin/bash
set -e
# --- SANDBOX RUN WRAPPER ---
# Usage:
#   ./sandbox_run.sh "Your task instruction here" [max_turns]
#   echo "Your task" | ./sandbox_run.sh
#   ./sandbox_run.sh  (interactive pipe mode)
# Flags:
#   --live          Stream logs live and expose status API
#   --status-port N Configure status port (default 8081)
#   --clean         Wipe sandbox-workspace before run
#   --snapshot NAME Create a .tar.gz snapshot of workspace before run
IMAGE_NAME="e-va-agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WORKSPACE_DIR="$SCRIPT_DIR/sandbox-workspace"
ENV_FILE="$PROJECT_ROOT/.env"
RESULT_LOG="$WORKSPACE_DIR/.e-va-conf/result.log"
STATUS_PORT="${STATUS_PORT:-8081}"
LIVE_MODE=false
CLEAN_MODE=false
SNAPSHOT_NAME=""
AGENT_MODE=""
# --- BUILD IMAGE IF MISSING ---
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[BUILD] Image '$IMAGE_NAME' not found. Building..."
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$PROJECT_ROOT"
    echo "[BUILD] Image built successfully."
fi
# --- PARSE FLAGS ---
while [ $# -gt 0 ]; do
    case "$1" in
        --live)
            LIVE_MODE=true
            shift
            ;;
        --status-port)
            STATUS_PORT="$2"
            shift 2
            ;;
        --clean)
            CLEAN_MODE=true
            shift
            ;;
        --snapshot)
            SNAPSHOT_NAME="$2"
            shift 2
            ;;
        --agent)
            AGENT_MODE="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done
# --- CLEAN MODE: Wipe workspace ---
if [ "$CLEAN_MODE" = true ]; then
    echo "[CLEAN] Wiping sandbox-workspace..."
    rm -rf "$WORKSPACE_DIR"
    mkdir -p "$WORKSPACE_DIR/.e-va-conf"
    echo "[CLEAN] Workspace wiped."
fi
# --- SNAPSHOT: Capture workspace state before run ---
if [ -n "$SNAPSHOT_NAME" ]; then
    SNAP_DIR="$WORKSPACE_DIR/.snapshots"
    mkdir -p "$SNAP_DIR"
    SNAP_FILE="$SNAP_DIR/${SNAPSHOT_NAME}.tar.gz"
    echo "[SNAPSHOT] Creating snapshot: $SNAP_FILE"
    tar -czf "$SNAP_FILE" -C "$WORKSPACE_DIR" . 2>/dev/null || true
    echo "[SNAPSHOT] Snapshot saved."
fi
# Ensure workspace directories exist
mkdir -p "$WORKSPACE_DIR/.e-va-conf"
# --- RESOLVE TASK INPUT ---
TASK=""
MAX_TURNS="${2:-}"
if [ -t 0 ]; then
    # Terminal input (not piped)
    if [ -n "$1" ]; then
        TASK="$1"
    else
        echo "Usage: $0 \"<task instruction>\" [max_turns]"
        echo "       echo \"<task>\" | $0"
        echo "       $0  (interactive pipe mode)"
        echo "Flags:"
        echo "  --live          Stream logs live and expose status API"
        echo "  --status-port N Configure status port (default 8081)"
        echo "  --agent NAME    Use specific agent (e.g., EXECUTOR)"
        exit 1
    fi
else
    # Piped input: read all stdin into TASK
    TASK="$(cat)"
fi
# --- STARTUP DEBUG LOG ---
DEBUG_LOG="$WORKSPACE_DIR/.e-va-conf/startup_debug.log"
{
    echo "=== STARTUP DEBUG LOG ==="
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    echo "=== ENVIRONMENT VARIABLES ==="
    env | sort | grep -E '^(EVA_|LLM_|OPENAI_|ANTHROPIC_|GOOGLE_|AZURE_)' || echo "(none)"
    echo ""
    echo "=== TASK CONTENT ==="
    echo "$TASK"
    echo ""
    echo "=== WORKSPACE DIRECTORY LISTING ==="
    find "$WORKSPACE_DIR" -maxdepth 3 -type f 2>/dev/null | head -100 || echo "(empty)"
    echo ""
    echo "=== .ENV FILE CONTENTS (MASKED) ==="
    if [ -f "$ENV_FILE" ]; then
        sed 's/=.*$/=<MASKED>/' "$ENV_FILE"
    else
        echo "(.env not found)"
    fi
    echo ""
    echo "=== DOCKER IMAGE INSPECT ==="
    docker image inspect "$IMAGE_NAME" --format '{{.Id}} {{.Config.Env}}' 2>/dev/null || echo "(inspect failed)"
    echo ""
    echo "=== FULL DOCKER RUN COMMAND ==="
    echo "docker run ${DOCKER_ARGS[*]} $IMAGE_NAME"
    echo ""
    echo "=== END STARTUP DEBUG LOG ==="
} > "$DEBUG_LOG" 2>&1
echo "[DEBUG] Startup debug log written to: $DEBUG_LOG"
# --- RUN CONTAINER ---
echo "[RUN] Starting sandbox container..."
# Build docker run arguments
# Using bridge network for isolation. Container can reach external LLM endpoints via NAT.
# If LLM_BASE_URL uses localhost, change to host.docker.internal in .env.
# Source .env file to pick up LLM configuration
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi
DOCKER_ARGS=(
    -i
    --rm
    --network bridge
    --add-host=host.docker.internal:host-gateway
    -p "${STATUS_PORT}:${STATUS_PORT}"
    -v "$WORKSPACE_DIR:/workspace"
    -v "$ENV_FILE:/opt/e-va/.env:ro"
    -v "$WORKSPACE_DIR/.e-va-conf/agent-logs:/opt/e-va/logs"
    --memory=4g
    --cpus=2
    -e "EVA_STATUS_PORT=$STATUS_PORT"
    -e "LLM_API_KEY=${LLM_API_KEY:-}"
    -e "LLM_BASE_URL=${LLM_BASE_URL:-http://localhost:8000/v1/chat/completions}"
    -e "LLM_MODEL=${LLM_MODEL:-default-model}"
)
# Auto-generate local config override if --agent EXECUTOR is used
if [ "$AGENT_MODE" = "EXECUTOR" ]; then
    echo "[AGENT] Using EXECUTOR agent mode. Generating local config override..."
    mkdir -p "$WORKSPACE_DIR/.e-va-conf"
    cat > "$WORKSPACE_DIR/.e-va-conf/config.lua" << 'LUAEOF'
local M = {}
function M.get()
    return {
        AGENTS = {
            EXECUTOR = {
                name = "EXECUTOR",
                prompt_file = "prompts/executor.md",
                allowed_tools = {
                    "shell", "read_file", "read_chunk", "create_file", "patch",
                    "search", "explore_tree", "task_complete", "outline",
                    "pin", "unpin", "optimize_context",
                },
                params = {
                    stream = true,
                    temperature = 0.1,
                    top_p = 0.95,
                    max_tokens = 16384,
                    repetition_penalty = 1.05,
                },
                model = "local_model",
            }
        },
        PIPELINE = {
            { stage = "EXECUTE", agents = { "EXECUTOR" }, mode = "sequential" }
        },
        PIPELINE_SETTINGS = {
            MAX_TURNS = 50,
            ABORT_ON_FATAL = true,
        }
    }
end
return M
LUAEOF
    # Also create the executor prompt
    mkdir -p "$WORKSPACE_DIR/prompts"
    cat > "$WORKSPACE_DIR/prompts/executor.md" << 'PROMPTEOF'
# SYSTEM DIRECTIVE: EXECUTOR
You are a direct-action Executor. Your sole purpose is to execute tasks immediately using available tools.
## RULES
1. **NO PLANNING**: Do not analyze, plan, or delegate. Execute immediately.
2. **BE CONCISE**: Keep responses brief. Show tool outputs, not commentary.
3. **USE TOOLS**: Use `shell` for system ops, `read_file`/`read_chunk` for reading, `create_file`/`patch` for writing.
4. **REPORT RESULTS**: At the end, summarize what was accomplished.
5. **CALL task_complete**: When the task is done, call `task_complete` to finish.
6. **RETRY LIMIT**: If a command fails 3 times, try a different approach or report the error.
7. **ONE COMMAND PER TURN**: Only one command block per response.
## AVAILABLE TOOLS
- `shell`: Execute shell commands
- `read_file`/`read_chunk`: Read file contents
- `create_file`/`patch`: Create or modify files
- `search`: Search codebase
- `explore_tree`: List directory structure
- `task_complete`: Signal task completion
- `outline`: Generate file outline
- `pin`/`unpin`/`optimize_context`: Manage context
==================================================
ENGINE DIRECTIVES:
1. PIPELINE: Use `task_complete` to finish.
2. ONE COMMAND PER TURN. Use batch tools if needed.
==================================================
PROMPTEOF
    echo "[AGENT] Local config and prompt generated for EXECUTOR mode."
fi
# Ensure agent-logs directory exists on host
mkdir -p "$WORKSPACE_DIR/.e-va-conf/agent-logs"
# Write task to a temp file for reliable stdin delivery
TASK_FILE=$(mktemp)
echo "$TASK" > "$TASK_FILE"
# Mount task file into container
DOCKER_ARGS+=(-v "$TASK_FILE:/tmp/eva_task_input:ro")
# Note: bridge network isolates container; outbound NAT allows LLM access
# Build container command arguments
CONTAINER_CMD=()
if [ -n "$AGENT_MODE" ]; then
    CONTAINER_CMD=("--agent" "$AGENT_MODE" "--pipe" ".")
    echo "[AGENT] Passing --agent $AGENT_MODE --pipe . to container"
fi
# Run container, passing task via stdin
if [ "$LIVE_MODE" = true ]; then
    # Live mode: run container in background, stream logs
    CONTAINER_ID=$(echo "$TASK" | docker run -d \
        "${DOCKER_ARGS[@]}" \
        "$IMAGE_NAME" "${CONTAINER_CMD[@]}" --pipe .) || true
    # Trap to clean up on exit
    cleanup() {
        echo "[CLEANUP] Stopping live log stream..."
        if [ -n "$LOG_PID" ] && kill -0 "$LOG_PID" 2>/dev/null; then
            kill "$LOG_PID" 2>/dev/null || true
            wait "$LOG_PID" 2>/dev/null || true
        fi
        # Stop container if still running
        if docker ps --format '{{.ID}}' | grep -q "^${CONTAINER_ID}"; then
            docker stop "$CONTAINER_ID" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT INT TERM
    echo "[LIVE MODE] Container started: $CONTAINER_ID"
    echo "Status API: http://localhost:${STATUS_PORT}/status"
    echo "Health API: http://localhost:${STATUS_PORT}/health"
    echo "Logs API:   http://localhost:${STATUS_PORT}/logs?n=50"
    echo "Press Ctrl+C to stop."
    echo ""
    # Stream logs in background
    docker logs -f "$CONTAINER_ID" 2>&1 &
    LOG_PID=$!
    # Wait for container to finish
    docker wait "$CONTAINER_ID" 2>/dev/null || true
    # Get exit code
    EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_ID" 2>/dev/null || echo "1")
    # Save output to result log
    docker logs "$CONTAINER_ID" 2>&1 > "$RESULT_LOG" || true
else
    # Normal mode: capture output with timeout safeguard (1 hour max)
    TIMEOUT_SECONDS=3600
    OUTPUT=$(timeout "$TIMEOUT_SECONDS" docker run \
        "${DOCKER_ARGS[@]}" \
        "$IMAGE_NAME" "${CONTAINER_CMD[@]}" < "$TASK_FILE" 2>&1) || true
    DOCKER_EXIT=$?
    # Clean up temp task file AFTER docker completes
    rm -f "$TASK_FILE"
    # Save raw output
    echo "$OUTPUT" > "$RESULT_LOG"
    # Post-run health check if exit code is non-zero
    if [ "$DOCKER_EXIT" -ne 0 ] 2>/dev/null; then
        echo "[HEALTH CHECK] Container exited with code $DOCKER_EXIT. Checking agent responsiveness..."
        HEALTH_RESP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${STATUS_PORT}/health" 2>/dev/null || echo "000")
        if [ "$HEALTH_RESP" = "200" ]; then
            echo "[HEALTH CHECK] Agent status server was responsive (HTTP $HEALTH_RESP) despite non-zero exit."
        else
            echo "[HEALTH CHECK] Agent status server was NOT responsive (HTTP $HEALTH_RESP)."
        fi
    fi
fi
# --- PARSE RESPONSE (only in non-live mode) ---
if [ "$LIVE_MODE" != true ]; then
    RESPONSE_START="=== RESPONSE START ==="
    RESPONSE_END="=== RESPONSE END ==="
    if echo "$OUTPUT" | grep -q "$RESPONSE_START"; then
        # Extract content between markers
        RESULT=$(echo "$OUTPUT" | sed -n "/$RESPONSE_START/,/$RESPONSE_END/{/$RESPONSE_START/d;/$RESPONSE_END/d;p;}")
        echo ""
        echo "========================================"
        echo "         SANDBOX RESULT SUMMARY"
        echo "========================================"
        echo "$RESULT"
        echo "========================================"
    else
        echo "[WARN] No response markers found in output. Attempting fallback extraction..."
        # Fallback 1: Try to extract the last JSON object from output
        JSON_FALLBACK=$(echo "$OUTPUT" | grep -o '{[^{}]*}' | tail -1)
        if [ -n "$JSON_FALLBACK" ]; then
            echo ""
            echo "========================================"
            echo "         SANDBOX RESULT (JSON FALLBACK)"
            echo "========================================"
            echo "$JSON_FALLBACK"
            echo "========================================"
        else
            # Fallback 2: Output the last 50 lines of the log
            echo ""
            echo "========================================"
            echo "         SANDBOX RESULT (LAST 50 LINES)"
            echo "========================================"
            echo "$OUTPUT" | tail -n 50
            echo "========================================"
        fi
        echo "Full output saved to: $RESULT_LOG"
    fi
fi
echo ""
echo "[INFO] Full raw output saved to: $RESULT_LOG"
echo "[INFO] Workspace contents at: $WORKSPACE_DIR"
# --- POST-MORTEM DIAGNOSTICS ---
HAS_FAILURE=false
if grep -qiE '(FATAL|ERROR)' "$RESULT_LOG" 2>/dev/null; then
    HAS_FAILURE=true
fi
if [ "$HAS_FAILURE" = true ]; then
    echo ""
    echo "========================================"
    echo "     [POST-MORTEM DIAGNOSTICS]"
    echo "========================================"
    # 1. Last 20 error/fatal lines from result.log
    echo ""
    echo "--- LAST ERROR/FATAL LINES FROM RESULT.LOG ---"
    grep -iE '(FATAL|ERROR)' "$RESULT_LOG" 2>/dev/null | tail -20 || echo "(none found)"
    # 2. Most recent agent log file
    AGENT_LOG_DIR="$WORKSPACE_DIR/.e-va-conf/agent-logs"
    if [ -d "$AGENT_LOG_DIR" ]; then
        LATEST_LOG=$(find "$AGENT_LOG_DIR" -name "*.log" -type f 2>/dev/null | sort | tail -1)
        if [ -n "$LATEST_LOG" ]; then
            echo ""
            echo "--- LAST 30 LINES OF MOST RECENT AGENT LOG: $(basename "$LATEST_LOG") ---"
            tail -30 "$LATEST_LOG" 2>/dev/null || echo "(could not read)"
        fi
    fi
    # 3. Structured log
    STRUCTURED_LOG="$WORKSPACE_DIR/.e-va-conf/structured.log"
    if [ -f "$STRUCTURED_LOG" ]; then
        echo ""
        echo "--- LAST 10 ENTRIES FROM STRUCTURED.LOG ---"
        tail -10 "$STRUCTURED_LOG" 2>/dev/null || echo "(could not read)"
    fi
    echo ""
    echo "========================================"
    echo "     [END POST-MORTEM DIAGNOSTICS]"
    echo "========================================"
fi