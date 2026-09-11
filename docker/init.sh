#!/bin/bash
set -e
# --- INIT SCRIPT FOR E-va AGENT ---
# Runs as root, fixes workspace ownership, then drops to chromeuser.
# --- BOOTSTRAP ENVIRONMENT LOGGING ---
{
    echo "[BOOTSTRAP] === INIT.SH STARTUP LOG ==="
    echo "[BOOTSTRAP] Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[BOOTSTRAP] PID: $$"
    echo "[BOOTSTRAP] User: $(whoami)"
    echo "[BOOTSTRAP] Arguments: $*"
    echo "[BOOTSTRAP] === ENVIRONMENT VARIABLES ==="
    env | sort
    echo "[BOOTSTRAP] === WORKSPACE CONTENTS ==="
    ls -la /workspace/ 2>/dev/null || echo "(workspace not accessible)"
    echo "[BOOTSTRAP] === .ENV FILE CONTENTS (MASKED) ==="
    if [ -f "/opt/e-va/.env" ]; then
        sed 's/=.*$/=<MASKED>/' /opt/e-va/.env
    else
        echo "(.env not found at /opt/e-va/.env)"
    fi
    echo "[BOOTSTRAP] === END STARTUP LOG ==="
} >&2
# 1. Fix workspace ownership recursively
WORKSPACE_DIR="/workspace"
chown -R chromeuser:chromeuser "$WORKSPACE_DIR" 2>/dev/null || true
# 2. Ensure .e-va-conf exists with correct permissions
CONF_DIR="$WORKSPACE_DIR/.e-va-conf"
mkdir -p "$CONF_DIR"
chown chromeuser:chromeuser "$CONF_DIR" 2>/dev/null || true
# 3. Capture stdin to a file BEFORE dropping privileges
STDIN_FILE="/tmp/eva_stdin"
if [ ! -t 0 ]; then
    timeout 5 cat > "$STDIN_FILE" 2>/dev/null || true
else
    echo "[BOOTSTRAP] Stdin is a terminal, skipping cat redirect" >&2
fi
STDIN_SIZE=$(wc -c < "$STDIN_FILE")
echo "[DEBUG] Captured stdin: $STDIN_SIZE bytes" >&2
if [ "$STDIN_SIZE" -gt 0 ]; then
    echo "[DEBUG] Stdin content preview: $(head -c 100 "$STDIN_FILE")" >&2
fi
# Fallback: if stdin is empty, check for mounted task file
if [ "$STDIN_SIZE" -eq 0 ] && [ -f "/tmp/eva_task_input" ]; then
    echo "[DEBUG] Stdin empty, falling back to /tmp/eva_task_input" >&2
    cp /tmp/eva_task_input "$STDIN_FILE"
    STDIN_SIZE=$(wc -c < "$STDIN_FILE")
    echo "[DEBUG] Fallback stdin: $STDIN_SIZE bytes" >&2
    if [ "$STDIN_SIZE" -gt 0 ]; then
        echo "[DEBUG] Fallback content preview: $(head -c 100 "$STDIN_FILE")" >&2
    fi
fi
chown chromeuser:chromeuser "$STDIN_FILE" 2>/dev/null || true
chmod 644 "$STDIN_FILE" 2>/dev/null || true
# 4. Source .env file to pick up LLM configuration
if [ -f "/opt/e-va/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source /opt/e-va/.env
    set +a
fi
# 4. Export environment variables so they survive the user switch
export PATH
export EVA_STATUS_PORT
export EVA_API_KEY
export EVA_MODEL
export EVA_MAX_TURNS
export EVA_TEMPERATURE
export STDIN_FILE
export LLM_API_KEY
export LLM_BASE_URL
export LLM_MODEL
# 5. Encode arguments safely for passing through su -c
EV_ARGS=""
for a in "$@"; do
    if [ -z "$EV_ARGS" ]; then
        EV_ARGS=$(printf '%q' "$a")
    else
        EV_ARGS="$EV_ARGS $(printf '%q' "$a")"
    fi
done
export EV_ARGS
# 6. Drop to chromeuser and exec e-va with stdin redirected from captured file
exec su -s /bin/bash chromeuser -c '
export PATH="$PATH"
export EVA_STATUS_PORT="$EVA_STATUS_PORT"
export EVA_API_KEY="$EVA_API_KEY"
export EVA_MODEL="$EVA_MODEL"
export EVA_MAX_TURNS="$EVA_MAX_TURNS"
export EVA_TEMPERATURE="$EVA_TEMPERATURE"
export STDIN_FILE="$STDIN_FILE"
export LLM_API_KEY="$LLM_API_KEY"
export LLM_BASE_URL="$LLM_BASE_URL"
export LLM_MODEL="$LLM_MODEL"
if [ -n "$EV_ARGS" ]; then
    eval "set -- \$EV_ARGS"
    if [ -s "$STDIN_FILE" ]; then
        exec /opt/e-va/e-va "$@" < "$STDIN_FILE"
    else
        exec /opt/e-va/e-va "$@"
    fi
else
    if [ -s "$STDIN_FILE" ]; then
        exec /opt/e-va/e-va < "$STDIN_FILE"
    else
        exec /opt/e-va/e-va
    fi
fi
'