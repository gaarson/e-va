#!/bin/bash
set -e
# --- INIT SCRIPT FOR E-va AGENT ---
# Runs as root, fixes workspace ownership, starts display stack, then drops to chromeuser.
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
# 5. Export environment variables so they survive the user switch
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
# 6. START DISPLAY STACK (cage + chrome + wayvnc)
# Only if DRM devices are available
if [ -d /dev/dri ] && [ "$(ls /dev/dri/renderD* 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "[DISPLAY] Starting display stack (cage + chrome + wayvnc)..." >&2
    
    # Setup XDG runtime dir
    mkdir -p /tmp/xdg && chmod 700 /tmp/xdg
    export XDG_RUNTIME_DIR=/tmp/xdg
    
    # Start cage (Wayland compositor) - use Intel card only to avoid NVIDIA conflicts
    # WLR_DRM_DEVICES restricts to specific render nodes
    export WLR_DRM_DEVICES="/dev/dri/renderD128"
    cage -x &
    CAGE_PID=$!
    echo "[DISPLAY] cage started (PID $CAGE_PID)" >&2
    
    # Wait for Wayland socket
    sleep 3
    if [ ! -S /tmp/xdg/wayland-0 ]; then
        echo "[DISPLAY] WARNING: Wayland socket not found, continuing anyway" >&2
    fi
    export WAYLAND_DISPLAY=wayland-0
    
    # Start Chrome with remote debugging
    google-chrome-stable \
        --no-sandbox \
        --ozone-platform=wayland \
        --disable-gpu \
        --remote-debugging-port=9222 \
        --new-window about:blank &
    CHROME_PID=$!
    echo "[DISPLAY] chrome started (PID $CHROME_PID)" >&2
    
    # Wait for Chrome DevTools port
    sleep 5
    
    # Start wayvnc
    wayvnc -a 0.0.0.0:5900 &
    WAYVNC_PID=$!
    echo "[DISPLAY] wayvnc started (PID $WAYVNC_PID)" >&2
    
    echo "[DISPLAY] Display stack ready: VNC on :5900, Chrome DevTools on :9222" >&2
else
    echo "[DISPLAY] No DRM render devices found, skipping display stack" >&2
fi
# 7. Encode arguments safely for passing through su -c
EV_ARGS=""
for a in "$@"; do
    if [ -z "$EV_ARGS" ]; then
        EV_ARGS=$(printf '%q' "$a")
    else
        EV_ARGS="$EV_ARGS $(printf '%q' "$a")"
    fi
done
export EV_ARGS
# 8. Drop to chromeuser and exec e-va with stdin redirected from captured file
exec su -m -s /bin/bash chromeuser -c '
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
export XDG_RUNTIME_DIR=/tmp/xdg
export WAYLAND_DISPLAY=wayland-0
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
