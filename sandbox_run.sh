#!/bin/bash
set -e
# --- SANDBOX RUN WRAPPER ---
# Usage:
#   ./sandbox_run.sh "Your task instruction here" [max_turns]
#   echo "Your task" | ./sandbox_run.sh
#   ./sandbox_run.sh  (interactive pipe mode)
IMAGE_NAME="e-va-agent"
WORKSPACE_DIR="$(pwd)/sandbox-workspace"
ENV_FILE="$(pwd)/.env"
RESULT_LOG="$WORKSPACE_DIR/.e-va-conf/result.log"
# Ensure workspace directories exist
mkdir -p "$WORKSPACE_DIR/.e-va-conf"
# --- BUILD IMAGE IF MISSING ---
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[BUILD] Image '$IMAGE_NAME' not found. Building..."
    docker build -t "$IMAGE_NAME" .
    echo "[BUILD] Image built successfully."
fi
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
        exit 1
    fi
else
    # Piped input: read all stdin into TASK
    TASK="$(cat)"
fi
# --- RUN CONTAINER ---
echo "[RUN] Starting sandbox container..."
# If max_turns is provided, we prepend it as a hint in the task
if [ -n "$MAX_TURNS" ]; then
    TASK="__MAX_TURNS=$MAX_TURNS__
$TASK"
fi
# Run container, passing task via stdin
OUTPUT=$(echo "$TASK" | docker run --rm \
    -v "$WORKSPACE_DIR:/workspace" \
    -v "$ENV_FILE:/opt/e-va/.env:ro" \
    --memory=4g \
    --cpus=2 \
    "$IMAGE_NAME" --pipe . 2>&1) || true
# --- SAVE RAW OUTPUT ---
echo "$OUTPUT" > "$RESULT_LOG"
# --- PARSE RESPONSE ---
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
    echo "[WARN] No response markers found in output."
    echo "Full output saved to: $RESULT_LOG"
fi
echo ""
echo "[INFO] Full raw output saved to: $RESULT_LOG"
echo "[INFO] Workspace contents at: $WORKSPACE_DIR"