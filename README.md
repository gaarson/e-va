
# E-va 
## Основные возможности (Core Features)

  * **Multi-Agent Pipeline**: Строго типизированный конвейер выполнения (Pipeline), разделенный на стадии (Planning, Review, Implementation) с использованием изолированных профилей (например, `ARCHITECT` и `CODER`).
  * **C-Native Fuzzy Patcher**: Ядро применения патчей (`patcher_core.so`) написано на C. Оно использует алгоритм нечеткого поиска (fuzzy matching) без аллокации памяти для сравнения строк, что позволяет успешно применять diff-блоки даже в случае галлюцинаций LLM с отступами (whitespaces/indentation).
  * **Advanced Context Management**:
      * Динамический подсчет токенов и строгая инверсия позиций (Positional Inversion) в XML-контексте.
      * **Context Pinning**: Возможность "прибивать" критические файлы в памяти, защищая их от вытеснения (eviction).
      * Сортировка файлов для дефрагментации KV-Cache модели.
  * **Sandboxed Execution & Circuit Breakers**: Выполнение shell-команд через изолированные процессы с таймаутами. Встроенный механизм Circuit Breaker, предотвращающий зацикливание агента при неудачных сборках (make/test).
  * **Human-in-the-Loop (HITL)**: Интерактивный режим для ревью и корректировки плана пользователем в реальном времени.

## Зависимости (Dependencies)

Проект спроектирован с упором на минимализм, но требует наличия определенных системных пакетов для работы I/O и сетевого стека.

**Системные зависимости (Debian/Ubuntu):**

  * `lua5.1` и `liblua5.1-0-dev` (Ядро выполнения)
  * `luarocks` (Пакетный менеджер)
  * `gcc` и `make` (Для компиляции C-расширения)
  * `ripgrep` (`rg`) (Критически важен для работы модулей `<cmd>search</cmd>` и `<cmd>outline</cmd>`)
  * `ca-certificates` (Для HTTPS запросов к LLM)

**Lua зависимости (устанавливаются через LuaRocks):**

  * `luajson` (Парсинг ответов LLM и файлов состояний)
  * `lua-http` (Асинхронные HTTP-запросы и обработка SSE-стримов)
  * `busted` и `luacov` (Опционально, для запуска unit-тестов)

## Установка и Запуск (Build & Run)

**1. Клонирование и сборка C-ядра:**

```bash
git clone <repository_url> E-va
cd E-va
make clean && make
```

**2. Установка Lua-модулей:**

```bash
luarocks install luajson --tree=lua_modules
luarocks install lua-http --tree=lua_modules
```

**3. Запуск агента:**
Для инициализации используется bash-обертка `e-va`, которая автоматически настраивает `LUA_PATH` и `LUA_CPATH`.

```bash
# Формат запуска: ./e-va [целевой_файл] "<инструкция>"
./e-va src/main.c "Refactor the memory allocation block to prevent segfaults"
```

*Альтернатива: Проект содержит `Dockerfile` с multi-stage сборкой. Вы можете запустить его в полностью изолированном контейнере без установки локальных зависимостей.*

-----

## Конфигурация: Режим обычного консольного чата (Interactive Console Chat)

По умолчанию E-va настроена на агрессивный инжиниринг (планирование -\> ревью -\> кодинг). Чтобы превратить проект в обычный LLM-чат для консультаций, необходимо переопределить настройки пайплайна в `config.lua`, оставив только интерактивную фазу.

Создайте директорию `.e-va-conf` в корне вашего проекта и добавьте туда файл `config.lua`. Движок спроектирован так, что локальная конфигурация переопределяет глобальную.

**Файл: `.e-va-conf/config.lua`**

```lua
local M = {}
local base_config = require("opt.e-va.config") -- или путь до глобального config.lua, если нужно наследоваться

function M.get()
    local os = require("os")
    local cfg = {}
    
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."
    cfg.CREATE_BACKUPS = false
    
    cfg.LIMITS = {
        MAX_CONTEXT = 32000,
        RESERVED_OUTPUT = 4000,
        SYSTEM_PROMPT_ESTIMATE = 1000,
        MEMORY_RATIO = 0.5,
        CHARS_PER_TOKEN = 3.5
    }

    cfg.AGENTS = {
        CHAT_BOT = {
            name = "CHAT_BOT",
            -- Укажите URL вашего OpenAI-совместимого эндпоинта (Ollama, TabbyAPI, LMStudio)
            url = "http://127.0.0.1:5000/v1/chat/completions",
            model = "your-model-name",
            params = {
                stream = true,
                temperature = 0.7,
                max_tokens = 4096,
                stop = { "<|im_end|>", "<|im_start|>" }
            },
            -- Промпт переопределяется на базовый
            prompt_file = "prompts/chat.md", 
            -- Разрешаем базовые тулы для чтения, если чат-боту нужен контекст проекта
            allowed_tools = { "read_file", "list_files", "search", "shell" }
        }
    }

    -- КЛЮЧЕВОЕ ИЗМЕНЕНИЕ: Оставляем только одну стадию в режиме "interactive"
    cfg.PIPELINE = {
        { stage = "CHAT_SESSION", agents = { "CHAT_BOT" }, mode = "interactive" }
    }

    return cfg
end

return M
```

**Файл: `.e-va-conf/prompts/chat.md`**

```md
You are an expert AI assistant. You are currently operating in a Human-in-the-Loop interactive shell.
Answer the user's questions directly and concisely. 
You have access to tools like <cmd>list_files</cmd> and <cmd>search:query</cmd> if the user asks questions about their local project.
```

**Запуск чата:**

```bash
./e-va "Let's chat about Linux kernel architecture"
```

Агент загрузит контекст и сразу перейдет в режим `=== HUMAN-IN-THE-LOOP (HITL) SESSION ===`, ожидая вашего инпута (`>>> USER -> CHAT_BOT:`). Выход из чата осуществляется командой `/exit`.


Если потребуется помощь с отладкой C-расширения или интеграцией `eBPF` метрик в этот пайплайн — обращайся. Архитектура к этому располагает.
