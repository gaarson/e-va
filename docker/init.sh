#!/bin/bash
set -e

# --- E-VA MODULAR INIT SYSTEM ---
AGENT_HOME="/opt/e-va"
WORKSPACE_DIR="/workspace"
TASK_FILE="/tmp/eva_task_input"
STDIN_CAPTURE="/tmp/eva_stdin"

# 1. Логирование окружения (только в stderr, чтобы не портить pipe-вывод)
{
    echo "[INIT] === E-VA MODULAR STARTUP ==="
    echo "[INIT] Time: $(date -u)"
    echo "[INIT] Modules: DESKTOP=${EVA_MODULE_DESKTOP:-0}, BROWSER=${EVA_MODULE_BROWSER:-0}"
} >&2

# 2. Права на workspace (init.sh запускается от root)
chown -R agentuser:agentuser "$WORKSPACE_DIR" 2>/dev/null || true
mkdir -p "$WORKSPACE_DIR/.e-va-conf"
chown agentuser:agentuser "$WORKSPACE_DIR/.e-va-conf" 2>/dev/null || true

# 3. Надежный захват задачи (Без агрессивных таймаутов)
# Приоритет 1: Файл, смонтированный из хоста (sandbox_run.sh)
# Приоритет 2: Pipe из stdin (docker run -i)
if [ -s "$TASK_FILE" ]; then
    export EVA_TASK_SOURCE="file"
    cp "$TASK_FILE" "$STDIN_CAPTURE"
elif [ ! -t 0 ]; then
    export EVA_TASK_SOURCE="stdin"
    cat > "$STDIN_CAPTURE" 2>/dev/null || true
else
    export EVA_TASK_SOURCE="tty"
    touch "$STDIN_CAPTURE"
fi
chown agentuser:agentuser "$STDIN_CAPTURE" 2>/dev/null || true
chmod 644 "$STDIN_CAPTURE" 2>/dev/null || true

# 4. Загрузка .env
if [ -f "$AGENT_HOME/.env" ]; then
    set -a
    source "$AGENT_HOME/.env"
    set +a
fi

# 5. ЗАПУСК МОДУЛЕЙ (Display Stack / Browser)
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

if [ "$EVA_MODULE_DESKTOP" = "1" ] && [ -d /dev/dri ] && [ "$(ls /dev/dri/renderD* 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "[MODULE:DESKTOP] Starting Wayland + VNC..." >&2
    export WLR_DRM_DEVICES="${WLR_DRM_DEVICES:-/dev/dri/renderD128}"
    export WLR_LIBINPUT_NO_DEVICES=1
    
    cage -x &
    sleep 3
    export WAYLAND_DISPLAY=wayland-0

    # Если есть браузерный модуль, запускаем Chrome внутри GUI
    if [ "$EVA_MODULE_BROWSER" = "1" ]; then
        google-chrome-stable --no-sandbox --ozone-platform=wayland --disable-gpu --remote-debugging-port=9222 --new-window about:blank &
        sleep 5
    fi

    wayvnc -a 0.0.0.0:5900 &
    echo "[MODULE:DESKTOP] Ready (VNC on 5900)" >&2

elif [ "$EVA_MODULE_BROWSER" = "1" ]; then
    echo "[MODULE:BROWSER] Starting Headless Chrome..." >&2
    # Headless режим без Wayland (экономия 200MB RAM и CPU)
    google-chrome-stable --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 --window-size=1920,1080 about:blank &
    sleep 3
    echo "[MODULE:BROWSER] Ready (CDP on 9222)" >&2
fi

# 6. Подготовка аргументов
EV_ARGS=""
for a in "$@"; do
    if [ -z "$EV_ARGS" ]; then
        EV_ARGS=$(printf '%q' "$a")
    else
        EV_ARGS="$EV_ARGS $(printf '%q' "$a")"
    fi
done
export EV_ARGS

# 7. Сброс привилегий через gosu (Правильно передает SIGTERM/SIGINT)
# gosu не создает лишних bash-процессов, в отличие от su -c
exec gosu agentuser /bin/bash -c '
    export PATH="$PATH"
    export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
    export WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
    export EVA_TASK_SOURCE="$EVA_TASK_SOURCE"
    
    if [ -n "$EV_ARGS" ]; then
        eval "set -- \$EV_ARGS"
    fi

    # Передаем stdin из захваченного файла, если он не пустой
    if [ -s "/tmp/eva_stdin" ]; then
        exec /opt/e-va/e-va "$@" < /tmp/eva_stdin
    else
        exec /opt/e-va/e-va "$@"
    fi
'
