# E-VA AGENT — Comprehensive Architecture Report

## 1. ОБЗОР АРХИТЕКТУРЫ

### 1.1 Высокоуровневая схема компонентов

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          E-VA AGENT SYSTEM                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────────────────────┐  │
│  │  e-va    │───▶│  agent/init  │───▶│         PIPELINE ENGINE          │  │
│  │ (bash)   │    │  (entry)     │    │  ┌─────────┐  ┌──────────────┐  │  │
│  └──────────┘    └──────┬───────┘    │  │STAGE 1  │─▶│  STAGE 2     │  │  │
│                         │            │  │ARCHITECT│  │  (CODER)     │  │  │
│                         ▼            │  └─────────┘  └──────────────┘  │  │
│                  ┌─────────────┐     └──────────────────────────────────┘  │
│                  │  CONFIG     │                                            │
│                  │  Loader     │     ┌──────────────────────────────────┐  │
│                  └─────────────┘     │         TURN EXECUTOR            │  │
│                                      │  ┌────────────────────────────┐  │  │
│  ┌──────────────────┐                │  │ LLM Request (streaming)    │  │  │
│  │  STATUS SERVER   │◀───────────────│  │ Command Parse & Execute    │  │  │
│  │  (HTTP :8080)    │                │  │ Multi-Stage Routing        │  │  │
│  └──────────────────┘                │  │ Loop Guard                 │  │  │
│                                      │  └────────────────────────────┘  │  │
│  ┌──────────────────┐                └──────────────────────────────────┘  │
│  │  JSON LOGGER     │                                                      │
│  │  (structured.log)│     ┌──────────────────────────────────────────────┐ │
│  └──────────────────┘     │              TOOL REGISTRY                   │ │
│                           │  read_file, shell, patch, create_file,       │ │
│  ┌──────────────────┐     │  search, explore_tree, delegate_plan, etc.   │ │
│  │  CONTEXT FLOW    │     └──────────────────────────────────────────────┘ │
│  │  (history, KB,   │                                                     │
│  │   compression)   │     ┌──────────────────────────────────────────────┐ │
│  └──────────────────┘     │         MULTI-STAGE EXECUTOR                 │ │
│                           │  Intent → Generate → Execute → Review        │ │
│  ┌──────────────────┐     └──────────────────────────────────────────────┘ │
│  │  LOOP GUARD      │                                                     │
│  │  (7 layers)      │     ┌──────────────────────────────────────────────┐ │
│  └──────────────────┘     │         IPC/MCP (C .so)                      │ │
│                           │  fork+pipe for MCP server processes           │ │
│  ┌──────────────────┐     └──────────────────────────────────────────────┘ │
│  │  PATCHER CORE    │                                                     │
│  │  (C .so)         │     ┌──────────────────────────────────────────────┐ │
│  └──────────────────┘     │         SANDBOX (Docker)                     │ │
│                           │  Isolated container, volume-mounted workspace │ │
│                           └──────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Потоки данных (ASCII diagram)

```
                    ┌─────────────────────────────────────────────────────────────┐
                    │                    EXTERNAL CALLER                           │
                    │  (shell script, CI pipeline, interactive terminal)          │
                    └───────────────┬─────────────────────────────┬───────────────┘
                                    │ stdin                       │ HTTP
                                    ▼                             ▼
                    ┌───────────────────────────┐    ┌──────────────────────────┐
                    │     E-VA AGENT PROCESS     │    │    STATUS SERVER (:8080) │
                    │                           │    │                          │
                    │  ┌─────────────────────┐  │    │  GET /health             │
                    │  │  PIPE MODE LOOP     │  │    │  GET /status             │
                    │  │  read_line("> ")    │  │    │  POST /cancel            │
                    │  └────────┬────────────┘  │    │  GET /logs?n=50          │
                    │           │               │    └──────────────────────────┘
                    │           ▼               │         ▲
                    │  ┌─────────────────────┐  │         │ update_status()
                    │  │  setup_and_run_task │  │         │
                    │  │  (per instruction)  │  │         │
                    │  └────────┬────────────┘  │         │
                    │           │               │         │
                    │           ▼               │         │
                    │  ┌─────────────────────┐  │         │
                    │  │  execute_pipeline   │──┼─────────┘
                    │  │  (stage iteration)  │  │
                    │  └────────┬────────────┘  │
                    │           │               │
                    │           ▼               │
                    │  ┌─────────────────────┐  │
                    │  │  run_agent_turn     │  │
                    │  │  (single LLM call)  │  │
                    │  └────────┬────────────┘  │
                    │           │               │
                    │     ┌─────┴─────┐         │
                    │     ▼           ▼         │
                    │  ┌──────┐   ┌──────────┐  │
                    │  │ LLM  │   │COMMAND   │  │
                    │  │ API  │   │EXECUTOR  │  │
                    │  │(HTTP)│   │(parse+   │  │
                    │  └──────┘   │execute)  │  │
                    │             └────┬─────┘  │
                    │                  │        │
                    │                  ▼        │
                    │  ┌──────────────────────┐ │
                    │  │  TOOL REGISTRY       │ │
                    │  │  (dispatch by name)  │ │
                    │  └──────────────────────┘ │
                    │                           │
                    └───────────────────────────┘
                                    │
                                    ▼ stdout
                    ┌─────────────────────────────────────────────────────────────┐
                    │  === PIPE MODE START ===                                    │
                    │  > [user input echoed]                                      │
                    │  === RESPONSE START ===                                     │
                    │  [agent output: analysis, tool results, final answer]       │
                    │  === RESPONSE END ===                                       │
                    │  >                                                            │
                    │  === RESPONSE START ===                                     │
                    │  [next response]                                            │
                    │  === RESPONSE END ===                                       │
                    │  ...                                                        │
                    │  === PIPE MODE EXIT ===                                     │
                    └─────────────────────────────────────────────────────────────┘
```

---

## 2. PIPE-РЕЖИМ

### 2.1 Активация (--pipe flag)

**Файл:** `agent/cli.lua:21-22`

```lua
elseif a == "--pipe" then
    is_pipe = true
```

Флаг `--pipe` устанавливает `parsed.is_pipe = true`. В `agent/init.lua:92`:

```lua
if parsed.is_pipe then
    status_server.update_status({agent_name="PIPE", current_turn=0, current_stage="pipe_mode", ...})
    task_module.run_pipe_mode(ctx, config, utils, logger, pipeline_module.execute_pipeline, turn_module.run_agent_turn, STATE_FILE)
    status_server.update_status({state="idle"})
    return -- Exit after pipe mode finishes
end
```

**Ключевое:** Pipe mode перехватывает выполнение ДО session restoration и batch processing. После завершения pipe mode процесс завершается (`return`).

### 2.2 Протокол ввода (stdin format)

**Файл:** `agent/task.lua:97-155`

Входные данные читаются построчно через `ui.input.read_line("> ")`. Каждый ряд обрабатывается как:

| Тип входа | Формат | Действие |
|-----------|--------|----------|
| Task instruction | Произвольный текст (не `/`) | Запускает полный pipeline на этот текст |
| Multi-line task | `=== MULTI-LINE START ===` ... `=== MULTI-LINE END ===` | Все строки между маркерами склеиваются в одну задачу (newline-separated) |
| Slash-команда | `/command [args]` | Обработка через `command_parser.parse()` |
| Терминация | `quit` или `exit` | Выход из pipe mode |
| Пустая строка | `""` | Игнорируется |

**Slash-команды в pipe mode** (`agent/task.lua:107-130`):

| Команда | Action | Поведение |
|---------|--------|-----------|
| `/messages` | MESSAGES | Дамп всей истории в лог |
| `/status` | STATUS | Печатает "Pipe mode ready" |
| `/help` | HELP | Печатает справку |
| `/abort` | ABORT | Выход из pipe mode |
| `/next_stage` | NEXT_STAGE | Недоступно в pipe mode |
| `/prev_stage` | PREV_STAGE | Недоступно в pipe mode |
| `/switch_stage` | SWITCH_STAGE | Недоступно в pipe mode |

### 2.3 Протокол вывода (stdout format)

**Файл:** `agent/task.lua:98,105,132-150`, `ui/printer.lua:46-47`

```
=== PIPE MODE START ===
> [prompt для пользователя, только в интерактивном режиме]
=== RESPONSE START ===
[полный вывод агента: анализ, результаты инструментов, финальный ответ]
=== RESPONSE END ===
>
=== RESPONSE START ===
[следующий ответ]
=== RESPONSE END ===
...
=== PIPE MODE EXIT ===
```

Маркеры генерируются через `ui.printer.pipe_marker(marker)` → простой `print(marker)`.

**Важно:** Между маркерами может быть ЛЮБОЙ вывод (LLM stream, tool outputs, warnings). Потребитель должен извлекать контент между `=== RESPONSE START ===` и `=== RESPONSE END ===`.

### 2.4 State machine (IDLE → EXECUTING → ...)

**Файл:** `command_executor.lua:5-9`

```lua
M.STATES = {
    IDLE = "IDLE",
    EXECUTING = "EXECUTING",
    WAITING_USER = "WAITING_USER",
    COMPLETED = "COMPLETED",
    ERROR = "ERROR"
}
```

Переходы:

```
                    ┌──────────────────────────────────────────────────┐
                    │                                                  │
                    ▼                                                  │
┌──────┐   parse    ┌───────────┐  validate  ┌───────────┐            │
│ IDLE │───────────▶│ EXECUTING │───────────▶│  IDLE     │            │
└──────┘  command   └─────┬─────┘  success   └───────────┘            │
    ▲                     │                                           │
    │                     │ validate fail                              │
    │                     ▼                                           │
    │              ┌────────────┐                                     │
    │              │ RETRY (≤3) │─── retry_count >= max ──▶ ┌───────┐│
    │              └────────────┘                           │ ERROR ││
    │                                                       └───────┘│
    │                                                                │
    │  ask_user                                                      │
    │◀───────────────────────────────────────────────────────────────┘
    │
    │  task_complete / delegate_plan
    ▼
┌───────────┐
│ COMPLETED │──▶ Pipeline advances to next stage
└───────────┘
```

**Pipeline-level signals** (возвращаемые `run_agent_turn`):

| Signal | Значение |
|--------|----------|
| `nil` | Обычный разговор (CONVERSATION) |
| `"AUTO_LOOP"` | Инструмент выполнен, агент продолжает |
| `"PIPELINE_NEXT_STAGE"` | Stage завершён, переход к следующему |
| `"ERROR"` | Критическая ошибка (сеть, пустой ответ) |

### 2.5 Терминация (quit/exit signals)

**Способы завершения pipe mode:**

1. **Явный:** `quit` или `exit` как отдельная строка stdin → `break` из while loop
2. **Slash-команда:** `/abort` → `break`
3. **EOF:** `read_line` возвращает `nil` при закрытии stdin → `break`
4. **SIGTERM/SIGINT:** Обработчик в `agent/init.lua:33-36` → flush logs → `os.exit(143/144)`
5. **MAX_TURNS:** Достигнут лимит `config.PIPELINE_SETTINGS.MAX_TURNS` (default 420) → `os.exit(1)`

**Docker-specific:** `STOPSIGNAL SIGQUIT` в Dockerfile. `tini` как PID 1 корректно reap'ит zombie-процессы.

### 2.6 Edge cases и ограничения

| Edge Case | Поведение | Источник |
|-----------|-----------|----------|
| Пустая строка в stdin | Игнорируется, цикл продолжается | `task.lua:103` |
| Строка начинается с `/` но не является валидной командой | Возвращает `cmd.action == "ERROR"` с сообщением | `task.lua:126-127` |
| LLM недоступен | 5 retries с exponential backoff (5s→10s→20s→40s→80s), затем FATAL | `turn.lua:115-131` |
| Пустой ответ от LLM | Классификация причины + recovery strategy | `turn.lua:248-270` |
| Duplicate command | Блокируется, inject warning, AUTO_LOOP | `command_flow.lua` |
| Circuit breaker (3 consecutive failures) | Tool в cooldown на 5 turns | `config.lua: CIRCUIT_BREAKER` |
| Loop guard (risk ≥ 0.85) | Глобальный блок, circuit breaker message | `loop_guard.lua` |
| stdin закрыт во время обработки | `read_line` вернёт nil → graceful exit | `ui/input.lua:592` |
| Очень длинная инструкция | Обрабатывается как есть, нет truncation на входе | `task.lua` |
| Несколько задач подряд | Каждая запускает полный pipeline (reset ctx) | `task.lua:133` |

**Ограничения pipe mode:**
- Нет поддержки `--agent` override внутри pipe session (только при запуске)
- Stage navigation (`/next_stage`, `/prev_stage`) недоступна
- Контекст сбрасывается между задачами (`ctx:reset()` в `setup_and_run_task`)

### 2.7 Примеры использования

**One-liner (CI/CD):**
```bash
echo "Analyze src/main.c for buffer overflows" | docker run -i --rm e-va-agent ./e-va --pipe
```

**Interactive session:**
```bash
docker run -it --rm \
    -v "$(pwd)/docker/sandbox-workspace:/workspace" \
    -v "$(pwd)/.env:/opt/e-va/.env:ro" \
    --memory=4g --cpus=2 \
    e-va-agent --pipe .
```

**Via sandbox_run.sh:**
```bash
./docker/sandbox_run.sh "Refactor the logging module"
cat task.txt | ./docker/sandbox_run.sh
./docker/sandbox_run.sh --clean --snapshot before-refactor "Implement feature X"
```

**With specific agent:**
```bash
./docker/sandbox_run.sh --agent EXECUTOR "Run tests and fix failures"
```

**Parsing output programmatically:**
```bash
RESULT=$(echo "What is 2+2?" | docker run -i --rm e-va-agent ./e-va --pipe | \
    sed -n '/=== RESPONSE START ===/,/=== RESPONSE END ===/{/=== RESPONSE START ===/d;/=== RESPONSE END ===/d;p;}')
echo "$RESULT"
```

---

## 3. DOCKER-СБОРКА

### 3.1 Dockerfile: stages, base image, layers

**Файлы:** `docker/Dockerfile.base` (73 строки), `docker/Dockerfile.browser` (29 строк), `docker/Dockerfile.desktop` (66 строк)

**Модульная 3-слойная сборка** (base → browser → desktop, каждый слой наследует предыдущий):

| Image | Base | Content | ENV Flag |
|-------|------|---------|----------|
| e-va-base | debian:unstable-slim | lua5.4, gcc, git, curl, luarocks, ripgrep, 28 Lua pkgs, source, C ext, agentuser, init.sh | none |
| e-va-browser | FROM e-va-base:latest | nodejs, npm, Chrome libs, chrome+wrapper, mcp | EVA_MODULE_BROWSER=1 |
| e-va-desktop | FROM e-va-browser:latest | cage+neatvnc+wayvnc from source | EVA_MODULE_DESKTOP=1 |


**Note:** Module activation is controlled by ENV flags set during image build: `EVA_MODULE_BROWSER=1` in Dockerfile.browser, `EVA_MODULE_DESKTOP=1` in Dockerfile.desktop. The base image runs headless by default.
**Key ENV vars set in image:**
```
LUA_PATH="/opt/e-va/lua_modules/share/lua/5.4/?.lua;..."
LUA_CPATH="/opt/e-va/lua_modules/lib/lua/5.4/?.so"
AGENT_HOME=/opt/e-va
PROJECT_ROOT=/workspace
CHROME_PATH=/usr/bin/google-chrome-stable
EVA_STATUS_PORT=8080
```

**ENTRYPOINT/CMD:**
```dockerfile
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/e-va/init.sh"]
CMD ["--pipe", "."]
```

### 3.2 docker-compose.sandbox.yml: services, networks, volumes

**Файл:** `docker/docker-compose.sandbox.yml`

```yaml
services:
  eva-sandbox:
    image: e-va-agent
    build:
      context: ..
      dockerfile: docker/Dockerfile.base
    container_name: eva-sandbox
    volumes:
      - ./docker/sandbox-workspace:/workspace
      - ${ENV_FILE:-../.env}:/opt/e-va/.env:ro
    environment:
      - LLM_API_KEY=${LLM_API_KEY:-}
      - LLM_BASE_URL=${LLM_BASE_URL:-http://localhost:8000/v1/chat/completions}
      - LLM_MODEL=${LLM_MODEL:-local_model}
      - EVA_STATUS_PORT=${EVA_STATUS_PORT:-8080}
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: '2'
    healthcheck:
      test: ["CMD-SHELL", "test -x /opt/e-va/e-va && ..."]
      interval: 30s
      timeout: 5s
      start_period: 5s
      retries: 3
    stdin_open: true
    tty: true
    command: ["--pipe", "."]
```

**Примечание:** Compose файл НЕ использует `--network host` (в отличие от `sandbox_run.sh`). Port mapping отсутствует в compose — для доступа к status server нужно добавить `ports: - "8080:8080"`. Build context указывает на корень проекта (`..`), так как Dockerfile выполняет `COPY . /opt/e-va`.


**Файл:** `.dockerignore` (21 строка)

| Excluded | Reason |
|----------|--------|
| `luacov.report.out`, `luacov.stats.out` | Test coverage artifacts |
| `*.patch` | Patch files |
| `run_tests.sh`, `test_api.sh`, `test_file.lua`, `api_tester.lua` | Test scripts |
| `logs/` | Runtime logs |
| `spec/`, `examples/` | Non-production dirs |
| `.git/` | Version control |
| `.e-va-conf/` | Runtime config/state |
| `lua_modules/` | Reinstalled via luarocks in image |
| `.env`, `.env.local` | Secrets |
| `*.key`, `*.pem`, `secrets/` | Credentials |

### 3.4 Переменные окружения (ENV, ARG)

| Variable | Source | Default | Purpose |
|----------|--------|---------|---------|
| `AGENT_HOME` | Dockerfile ENV | `/opt/e-va` | Path to agent code |
| `PROJECT_ROOT` | Dockerfile ENV | `/workspace` | Working directory |
| `LLM_API_KEY` | .env / runtime | — | API key for LLM |
| `LLM_BASE_URL` | .env / runtime | `http://localhost:8000/v1/chat/completions` | LLM endpoint |
| `LLM_MODEL` | .env / runtime | `default-model` | Model identifier |
| `EVA_STATUS_PORT` | Dockerfile ENV / runtime | `8080` | Status server port |
| `CHROME_PATH` | Dockerfile ENV | `/usr/bin/google-chrome-stable` | Chrome binary path |
| `LUA_PATH` | Dockerfile ENV | (see above) | Lua module search path |
| `LUA_CPATH` | Dockerfile ENV | (see above) | Lua C module search path |
| `GIT_EVA_URL` | Runtime env | — | If set, clones repo at startup |
| `ENV_PATH` | Set by `e-va` script | — | Path to .env file |
| `STDIN_FILE` | Set by `init.sh` | `/tmp/eva_stdin` | Captured stdin file |

**Priority chain for LLM config** (`agent/config.lua:apply_env_overrides`):
1. Environment variables (`LLM_API_KEY`, `LLM_BASE_URL`, `LLM_MODEL`) — highest
2. `.e-va-conf/config.lua` (local overrides)
3. `config.lua` (base defaults)

### 3.5 Привилегии и security

| Aspect | Implementation |
|--------|---------------|
| **User** | `agentuser` (non-root), created via `useradd -m -s /bin/bash agentuser` |
| **Privilege drop** | `init.sh` runs as root → `chown` workspace → `gosu agentuser -c '...'` (preserves env vars) |
| **Sudo restriction** | Only Chrome commands: `agentuser ALL=(ALL) NOPASSWD: /usr/bin/google-chrome-stable, /usr/bin/google-chrome-stable-orig` |
| **Chrome sandbox** | Disabled via wrapper: `--no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage` |
| **Resource limits** | `--memory=4g --cpus=2` (sandbox_run.sh) / `deploy.resources.limits` (compose) |
| **Network** | `--network host` (sandbox_run.sh) — FULL host network access! |
| **Volumes** | Workspace RW, .env RO |
| **STOPSIGNAL** | `SIGQUIT` |
| **Process manager** | `tini` as PID 1 (zombie reaping) |
| **Shell sanitization** | Blocks: sudo, rm -rf /, writes to /etc/, curl\|sh, wget\|sh |

### 3.6 GIT_EVA_URL mechanism (clone at runtime)

**Файл:** `e-va:36-48`

```bash
if [ -n "$GIT_EVA_URL" ]; then
    echo "Cloning $GIT_EVA_URL ..."
    rm -rf "$AGENT_HOME"/*; rm -rf "$AGENT_HOME"/.* 2>/dev/null
    git clone "$GIT_EVA_URL" /tmp/repo
    if [ -n "$GIT_EVA_SHA256" ]; then
        ACTUAL_HASH=$(tar -C /tmp/repo -cf - . | sha256sum | awk '{print $1}')
        if [ "$ACTUAL_HASH" != "$GIT_EVA_SHA256" ]; then
            echo "[FATAL] SHA256 mismatch: expected $GIT_EVA_SHA256, got $ACTUAL_HASH" >&2
            rm -rf /tmp/repo
            exit 1
        fi
        echo "[OK] SHA256 verified."
    fi
    cp -a /tmp/repo/. "$AGENT_HOME"/
    rm -rf /tmp/repo
fi
```

**Purpose:** Allows updating agent code without rebuilding the image. At container startup, if `GIT_EVA_URL` is set, the agent clones the latest code from the specified Git URL into `$AGENT_HOME` (`/opt/e-va`). Optional `GIT_EVA_SHA256` env var enables integrity verification before deployment.

### 3.7 Команды сборки и запуска

```bash
# Build (from project root)
docker build -t e-va-base -f docker/Dockerfile.base && docker build -t e-va-browser -f docker/Dockerfile.browser && docker build -t e-va-desktop -f docker/Dockerfile.desktop .

# Run one-shot task
echo "Your task" | docker run -i --rm e-va-agent ./e-va --pipe

# Interactive
docker run -it --rm e-va-agent ./e-va --pipe

# With workspace
docker run -it --rm \
    -v "$(pwd)/docker/sandbox-workspace:/workspace" \
    -v "$(pwd)/.env:/opt/e-va/.env:ro" \
    --memory=4g --cpus=2 \
    --network host \
    e-va-agent --pipe .

# Via compose (from project root)
docker compose -f docker/docker-compose.sandbox.yml run --rm eva-sandbox

# Via sandbox wrapper (CWD-independent — works from any directory)
./docker/sandbox_run.sh "Task instruction"
./docker/sandbox_run.sh --live --status-port 9090 "Task"
./docker/sandbox_run.sh --clean --snapshot pre-change "Task"
./docker/sandbox_run.sh --agent EXECUTOR "Direct execution task"
```

---


## 4. ВНЕШНИЕ ИНТЕРФЕЙСЫ СВЯЗИ

### 4.1 Pipe (stdin/stdout)

Already documented in Section 2. Key characteristics:
- **Protocol:** Line-based text
- **Markers:** `=== PIPE MODE START/EXIT ===`, `=== RESPONSE START/END ===`
- **Termination:** `quit`/`exit`/EOF/SIGTERM
- **No auth:** Direct process I/O

### 4.2 HTTP status server

**Файл:** `status_server.lua`

| Endpoint | Method | Auth | Response |
|----------|--------|------|----------|
| `/health` | GET | None | `{"status":"ok"}` |
| `/status` | GET | None | Full status JSON (agent_name, turn, stage, tokens, state, uptime) |
| `/cancel` | POST | None | Sets `_cancel_requested = true` |
| `/logs?n=N` | GET | None | Last N log entries (default 50, max 1000 ring buffer) |

**Port:** `EVA_STATUS_PORT` env var or default 8080. Fallback: tries ports 8080-8090 sequentially.

**Implementation:** Pure Lua using `luasocket`. Non-blocking poll model (`M.poll()` called from main loop). No TLS, no authentication.

**Status fields:**
```json
{
    "agent_name": "ARCHITECT",
    "current_turn": 42,
    "current_stage": "IMPLEMENTATION",
    "stage_index": 2,
    "total_stages": 2,
    "tokens_used": 15234,
    "state": "running",
    "uptime_seconds": 342.5
}
```

### 4.3 IPC/MCP (C shared library)

**Файл:** `ipc_mcp.c` (206 строк)

**Architecture:**
```
Lua VM
  │
  ├── ipc_mcp.spawn_mcp("npx chrome-devtools-mcp ...")
  │       │
  │       ├── fork()
  │       ├── pipe(pipe_in[2])   ← parent writes, child reads (stdin)
  │       ├── pipe(pipe_out[2])  ← child writes, parent reads (stdout)
  │       ├── dup2 + execl("/bin/sh", "sh", "-c", cmd)
  │       └── Returns MCP_Process userdata to Lua
  │
  ├── ipc_mcp.mcp_write(proc, json_payload)
  │       └── fprintf(proc->in, "%s\n", payload) + fflush
  │
  ├── ipc_mcp.mcp_read(proc)
  │       └── getline(&line, &len, proc->out) → returns line or nil
  │
  └── GC: __gc metamethod → fclose pipes + kill(SIGTERM) + waitpid(WNOHANG)
```

**Protocol:** Line-based JSON over pipes (standard MCP stdio transport). Each message is a single line terminated by `\n`.

**Safety:** `signal(SIGPIPE, SIG_IGN)` registered at module load to prevent crashes when MCP process dies.

**Build:** `gcc -O3 -Wall -Wextra -fPIC -shared -lpthread -o ipc_mcp.so ipc_mcp.c`

### 4.4 File-based interfaces

| Path | Purpose | Format |
|------|---------|--------|
| `.e-va-conf/task.txt` | Default task instruction (if no CLI arg) | Plain text |
| `.e-va-conf/config.lua` | Local config overrides | Lua module |
| `.e-va-conf/.state.json` | Session state (atomic save) | JSON snapshot |
| `.e-va-conf/.state.json.bak` | Backup state | JSON snapshot |
| `.e-va-conf/structured.log` | Structured JSON logs | NDJSON |
| `.e-va-conf/pictures/` | Images auto-attached each turn | PNG/JPEG |
| `.e-va-conf/result.log` | Sandbox result output | Raw text |
| `.e-va-conf/startup_debug.log` | Bootstrap diagnostics | Plain text |
| `.e-va-conf/shell_audit.log` | Shell command audit trail | Plain text |
| `.e-va-conf/.multi_stage_state.json` | Multi-stage executor state | JSON |
| `logs/run_*.log` | Per-run log files | Plain text |
| `docker/sandbox-workspace/` | Mounted project workspace | Files |

### 4.5 Shell exec (direct process spawning)

The `shell` tool allows the agent to execute arbitrary shell commands within the container. Protected by:
- **Sanitization** (`command_executor.lua:_sanitize_shell_command`): blocks dangerous patterns
- **Tool permissions**: only agents with `"shell"` in `allowed_tools` can use it
- **Loop guard**: prevents repeated identical commands
- **Audit log**: commands logged to `.e-va-conf/shell_audit.log`

### 4.6 Сравнительная таблица интерфейсов

| Interface | Direction | Protocol | Auth | Latency | Use Case |
|-----------|-----------|----------|------|---------|----------|
| **Pipe (stdin/stdout)** | Bidirectional | Line-based text + markers | None (process-level) | Low | Primary task input/output, CI/CD |
| **HTTP Status Server** | External → Agent (poll/cancel) | HTTP/1.1 JSON | None | Medium | Monitoring, cancellation, health checks |
| **IPC/MCP** | Agent ↔ MCP Server | Line-based JSON over pipes | None (process-level) | Low | Browser automation, external tool servers |
| **File-based** | Bidirectional | Files on filesystem | OS permissions | Variable | Config, state persistence, logs, images |
| **Shell exec** | Agent → OS | POSIX shell | OS user (agentuser) | Variable | System operations, builds, tests |
| **LLM API** | Agent → LLM Server | HTTP streaming (SSE) | Bearer token | High (network) | Core AI reasoning |

---

## 5. SANDBOX

### 5.1 Архитектура sandbox

```
┌─────────────────────────────────────────────────────────────────┐
│ HOST                                                             │
│                                                                 │
│  sandbox_run.sh                                                 │
│       │                                                         │
│       │ docker run                                              │
│       ▼                                                         │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ CONTAINER (e-va-agent)                                   │    │
│  │                                                          │    │
│  │  tini (PID 1)                                           │    │
│  │       │                                                  │    │
│  │       ▼                                                  │    │
│  │  init.sh (root)                                          │    │
│  │       │ chown workspace                                  │    │
│  │       │ capture stdin → /tmp/eva_stdin                   │    │
│  │       │ source .env                                      │    │
│       │ module check (EVA_MODULE_DESKTOP/BROWSER)              │    │
│  │       │ gosu agentuser                                    │    │
│  │       ▼                                                  │    │
│  │  e-va --pipe .  < /tmp/eva_stdin                         │    │
│  │       │                                                  │    │
│  │       ▼                                                  │    │
│  │  lua agent.lua --pipe .                                  │    │
│  │                                                          │    │
│  │  Volumes:                                                │    │
│  │    /workspace ←→ ./docker/sandbox-workspace (RW)          │    │
│  │    /opt/e-va/.env ←→ ./.env (RO)                         │    │
│  │    /opt/e-va/logs ←→ ./docker/sandbox-workspace/.e-va-conf/agent-logs │
│  │                                                          │    │
│  │  Network: --network host (full host network)             │    │
│  │  Resources: --memory=4g --cpus=2                         │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Изоляция (network, filesystem, processes)

| Dimension | Isolation Level | Details |
|-----------|----------------|---------|
| **Filesystem** | Partial | Workspace isolated via volume mount. Agent code baked into image (read-only effectively since agentuser can't write to /opt/e-va). BUT: `--network host` means no network isolation. |
| **Network** | NONE | `--network host` gives container direct access to host network stack. Can reach any host service. |
| **Processes** | Container namespace | Separate PID namespace. `tini` as init. Chrome runs with `--no-sandbox`. |
| **Resources** | Limited | 4GB RAM, 2 CPUs enforced via cgroups. |
| **User** | Non-root | `agentuser` with restricted sudo (Chrome only). |
| **Time** | Limited | `timeout 3600` in sandbox_run.sh (1 hour max). |

**Security gaps:**
- `--network host` exposes entire host network
- No seccomp/apparmor profiles
- Chrome `--no-sandbox` reduces browser isolation
- Shell tool can execute any command as agentuser

### 5.3 sandbox_run.sh: оркестрация

**Файл:** `docker/sandbox_run.sh` (CWD-independent via SCRIPT_DIR/PROJECT_ROOT resolution)

**Flow:**
1. Check if Docker image exists → build if missing
2. Parse flags: `--live`, `--status-port`, `--clean`, `--snapshot`, `--agent`
3. Clean workspace if `--clean`
4. Create snapshot if `--snapshot NAME`
5. Resolve task input (arg or stdin)
6. Write startup debug log
7. Source `.env` for LLM config
8. Build `docker run` arguments
9. If `--agent EXECUTOR`: generate local config + prompt override
10. Run container (live mode: background + log stream; normal: foreground with timeout)
11. Extract result (tiered fallback: markers → JSON → last 50 lines)
12. Post-mortem diagnostics if errors detected

**Result extraction priority:**
1. Content between `=== RESPONSE START ===` and `=== RESPONSE END ===`
2. Last JSON object in output
3. Last 50 lines of log

### 5.4 Ограничения и возможности

| Limitation | Workaround |
|------------|-----------|
| Single task per container run | Run multiple containers or use interactive pipe mode |
| No persistent state between runs (unless workspace volume retained) | Use `--snapshot` for reproducibility |
| 1-hour timeout | Edit `TIMEOUT_SECONDS` in sandbox_run.sh |
| No GPU passthrough | Add `--gpus all` to DOCKER_ARGS |
| Network not isolated | Use `--network none` + specific port mappings (breaks LLM access) |
| No concurrent execution | Run multiple containers with different workspace dirs |

---

## 6. КОНФИГУРАЦИЯ И ПАРАМЕТРЫ

### 6.1 Все env vars и их влияние

| Variable | Affects | Default | Priority |
|----------|---------|---------|----------|
| `LLM_API_KEY` | All agents' `token` field | Falls back to `OPENAI_API_KEY` | Highest (env override) |
| `OPENAI_API_KEY` | Fallback API key | — | Second |
| `LLM_BASE_URL` | All agents' `url` field | `http://localhost:8000/v1/chat/completions` | Highest |
| `LLM_MODEL` | All agents' `model` field | `default-model` | Highest |
| `EVA_STATUS_PORT` | Status server bind port | `8080` | Runtime |
| `AGENT_HOME` | Agent code location | Script-derived | Startup |
| `PROJECT_ROOT` | Working directory | `$(pwd)` | Startup |
| `ENV_PATH` | .env file location | Auto-detected | Startup |
| `GIT_EVA_URL` | Runtime code update | — | Startup |
| `STDIN_FILE` | Captured stdin path | `/tmp/eva_stdin` | Docker init |
| `EVA_API_KEY` | Legacy (exported but unused in code) | — | — |
| `EVA_MODEL` | Legacy (exported but unused in code) | — | — |
| `EVA_MAX_TURNS` | Legacy (exported but unused in code) | — | — |
| `EVA_TEMPERATURE` | Legacy (exported but unused in code) | — | — |

### 6.2 config.lua: ключевые секции

| Section | Key Parameters | Purpose |
|---------|---------------|---------|
| `LIMITS` | MAX_CONTEXT=160000, RESERVED_OUTPUT=5000, CHARS_PER_TOKEN=3.5 | Token budget management |
| `CONTEXT_FLOW.storage` | max_history_messages=100, max_history_tokens=50000, squash_threshold_tokens=100000 | History pruning |
| `CONTEXT_FLOW.compression` | zone1_size=5, zone2_size=10, max_tool_output_bytes=8192 | Context compression zones |
| `CONTEXT_FLOW.command_flow` | strict_parsing=true, max_retries=3, dedup_exceptions=[...] | Command parsing behavior |
| `PIPELINE_SETTINGS` | MAX_TURNS=420, ABORT_ON_FATAL=true | Pipeline limits |
| `HANDOFF` | enabled=true, clear_history="smart", max_memo_tokens=12000 | Stage transition data passing |
| `CIRCUIT_BREAKER` | threshold=3, cooldown_turns=5 | Tool failure handling |
| `IMAGE_CONFIG` | max_images_per_turn=10, max_image_dimension=1024 | Image processing |
| `AGENTS.ANALYZER` | is_reasoning=true, allowed_tools=[read,search,shell,delegate_plan,...] | Analysis agent config |
| `AGENTS.ARCHITECT` | is_reasoning=true, allowed_tools=[read,search,shell,delegate_plan,ask_user,...] | Planning agent config |
| `AGENTS.CODER` | is_reasoning=false, multi_stage_tools=[create_file,patch], allowed_tools=[patch,create_file,read,shell,task_complete] | Implementation agent config |
| `PIPELINE` | [{REVIEW_AND_CHAT, ARCHITECT, interactive}, {IMPLEMENTATION, CODER, sequential}] | Stage definitions |

### 6.3 .e-va-conf: runtime config

**File:** `.e-va-conf/config.lua` (6 lines in this project)

This file provides **local overrides** that are deep-merged onto the base `config.lua`. It's the primary mechanism for per-project customization without modifying agent code.

```lua
-- Example structure:
local M = {}
function M.get()
    return {
        AGENTS = { ... },      -- Override specific agents
        PIPELINE = { ... },    -- Override pipeline stages
        PIPELINE_SETTINGS = { MAX_TURNS = 50 }  -- Override limits
    }
end
return M
```

**Merge order:** `config.lua` (base) → `.e-va-conf/config.lua` (local) → env vars (highest priority)

---

## 7. ИЗВЕСТНЫЕ ОГРАНИЧЕНИЯ И РИСКИ

### 7.1 Безопасность

| Risk | Severity | Mitigation | Status |
|------|----------|------------|--------|
| `--network host` в sandbox_run.sh | **HIGH** | Контейнер имеет полный доступ к сети хоста. Может сканировать порты, атаковать локальные сервисы. | Не исправлено. Compose-файл не использует host network, но sandbox_run.sh — да. |
| Chrome `--no-sandbox` | **MEDIUM** | Браузер без песочницы. Уязвимости в Chrome могут привести к RCE как agentuser. | Принято как trade-off для работы в Docker. |
| Shell tool без полноценной изоляции | **MEDIUM** | Агент может выполнить любую команду как agentuser. Sanitization блокирует только известные паттерны (sudo, rm -rf /, curl\|sh). | Частично: есть blacklist, но нет whitelist/allowlist. |
| HTTP status server без auth | **LOW** | Любой процесс на хосте может читать статус и отправлять cancel. | Принято: сервер предназначен для локального мониторинга. |
| `.env` mounted read-only | **LOW** | API keys доступны внутри контейнера. Если агент скомпрометирован — ключи утекают. | Стандартная практика. |
| `GIT_EVA_URL` — arbitrary code execution | **MEDIUM** | Клонирование произвольного репозитория при старте. Если URL подменён — исполняется злонамеренный код. | Поддерживается `GIT_EVA_SHA256` env var для верификации хэша репозитория перед развёртыванием. |
| Sudoers для Chrome | **LOW** | Ограничен только Chrome бинарником. | Корректно реализовано. |
| No seccomp/AppArmor profiles | **MEDIUM** | Нет syscall filtering. | Не настроено. |

### 7.2 Надёжность (race conditions, deadlocks)

| Issue | Description | Impact |
|-------|-------------|--------|
| **stdin capture (no timeout)** | `cat > "$STDIN_CAPTURE" 2/dev/null || true` — блокируется до EOF. При медленном pipe может ждать долго, но данные не теряются. | Потенциальная задержка при очень медленных источниках. Fallback: `/tmp/eva_task_input` (mounted file). |
| **Status server poll model** | `M.poll()` вызывается из main loop. Если main loop заблокирован (долгий LLM request), HTTP запросы не обрабатываются. | Timeout на `/health`, `/status` во время активных turn'ов. |
| **Atomic state save** | Используется `tmp + rename`. Корректно для single-process. Но если процесс убивается между write и rename — tmp файл остаётся. | Мелкий: cleanup при следующем запуске. |
| **Lua GC vs C resources** | `ipc_mcp.so` использует `__gc` для закрытия pipes и kill процесса. Lua GC не детерминирован — MCP процесс может жить дольше необходимого. | Утечка ресурсов при частом создании MCP процессов. |
| **Circuit breaker state in memory only** | Сбрасывается при рестарте. | После crash+restart agent "забывает" о предыдущих failures. |
| **Multi-stage executor max_iterations=3** | Жёсткий лимит. Если patch не сходится за 3 попытки — отказ. | False negative на сложных файлах. |

### 7.3 Масштабируемость

| Limitation | Current State | Bottleneck |
|------------|---------------|------------|
| **Single process** | Один Lua процесс = один агент. Нет параллельных задач. | CPU-bound: LLM wait time не используется для других задач. |
| **Sequential pipeline** | Stages выполняются последовательно. Parallel mode существует (coroutines), но ограничен одним LLM endpoint. | Нет fan-out на разные модели/эндпоинты. |
| **Context window 160K tokens** | Hard limit. Compression helps but degrades quality. | Для больших кодовых баз — потеря контекста. |
| **MAX_TURNS=420** | Global limit per pipeline run. | Для крупных задач может быть недостаточно. |
| **No horizontal scaling** | Каждый контейнер = одна задача. Нет queue/load balancer. | Для batch processing нужно вручную запускать N контейнеров. |
| **State in single JSON file** | `.state.json` растёт линейно. Нет sharding. | Для очень длинных сессий — медленный parse/save. |
| **Log ring buffer 1000 entries** | In-memory only. При перезагрузке теряется. | Для аудита недостаточно. |
| **No connection pooling for LLM** | Каждый request — новый TCP connection (через cqueues/luasocket). | Overhead при частых коротких запросах. |

---

## Резюме: Слабые стороны системы (для само-модернизации)

| # | Проблема | Рекомендация |
|---|----------|--------------|
| 1 | `--network host` в sandbox_run.sh | Заменить на `--network bridge` + explicit port mappings |
| 2 | stdin capture блокируется до EOF без timeout | Добавить optional timeout или signal-based approach для non-interactive sources |
| 3 | Status server не отвечает во время LLM call | Вынести в отдельный coroutine/thread (cqueues уже установлен) |
| 4 | No structured error codes в pipe output | Добавить JSON envelope: `{"type":"error","code":"LLM_UNREACHABLE","msg":"..."}` |
| 5 | Circuit breaker state volatile | Persist в `.e-va-conf/.circuit_breaker.json` |
