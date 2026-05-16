# Autonomous LLM Agent Framework

## ⚙️ 1. Архитектура и Изоляция (Environment & Docker)

Фреймворк спроектирован с учетом изоляции процессов. Мы рекомендуем использовать контейнеризацию для защиты хост-системы от сгенерированного LLM кода.

### Локальная сборка (Bare Metal)

Требуются: `gcc`, `make`, `lua5.1`, `luarocks`, `ripgrep`.

```bash
make clean && make  # Компиляция patcher_core.so
luarocks install luajson http busted --tree=lua_modules

```

### Docker Runtime & eBPF Capabilities

E-va поставляется с multi-stage `Dockerfile`. Runtime-стадия выполняется от имени unprivileged пользователя (`USER agent`).

**Стандартный безопасный запуск:**

```bash
docker run --rm -it -v $(pwd):/home/agent/workspace e-va-agent

```

**Продвинутый запуск (для использования инструмента `<cmd>trace_execution</cmd>`):**
Инструмент `trace_execution` использует `bpftrace` (eBPF) для профилирования бинарников на лету. Это требует взаимодействия с kernel space. Для работы этого инструмента контейнер должен запускаться с расширенными правами:

```bash
docker run --rm -it \
  --user root \
  --cap-add=SYS_ADMIN --cap-add=BPF --cap-add=PERFMON \
  -v /sys/kernel/debug:/sys/kernel/debug:rw \
  -v $(pwd):/home/agent/workspace \
  e-va-agent

```

---

## 🚀 2. Жизненный цикл проекта: Bootstrap Protocol

Не пытайтесь писать конфигурацию вручную. E-va использует Мета-Агента (Bootstrapper) для первичного анализа вашего кода и генерации scaffolding-структуры.

**Команда:**

```bash
./e-va --bootstrap

```

**Что происходит под капотом:**

1. Bootstrapper сканирует AST проекта (через `explore_tree`) и запускает линтеры/тесты.
2. Создается директория `.e-va-conf/`.
3. Генерируется `config.lua` с оптимальным `PIPELINE` и лимитами токенов под ваш проект.
4. В `.e-va-conf/prompts/` создаются Markdown-инструкции для каждого агента с внедренными директивами (Anti-Hallucination, MUC Rule).

---

## 💻 3. CLI: Режимы исполнения (Execution Modes)

CLI парсер E-va представляет собой state machine, поддерживающую как полный прогон пайплайна, так и точечный вызов агентов.

### Стандартный пайплайн (Global Scope)

Движок читает `TASKS` из `config.lua` или берет задачу из аргументов и прогоняет ее через все стадии (Planning -> Review -> Implementation).

```bash
./e-va src/server.c "Optimize the select() loop to use epoll"

```

*Если аргументы не переданы, движок прочитает задачу из `.e-va-conf/task.txt`.*

### Прямое исполнение (Direct Execution Override)

Если вам нужен конкретный агент (например, вы хотите пропустить фазу `ARCHITECT` и сразу заставить `CODER` писать код), используйте флаг `--agent`. Движок динамически перепишет AST конфигурации, свернув пайплайн до одной стадии:

```bash
./e-va --agent CODER src/main.lua "Fix the indexing bug on line 42"

```

---

## 🧠 4. Управление памятью: Positional Context Inversion

Главная проблема LLM — "забывание" контекста (Lost in the Middle). E-va решает это через жестко типизированные XML-блоки и алгоритмы приоритетного вытеснения (Eviction).

Формат памяти, который видит LLM:

1. **`[SYSTEM MEMORY]`**: Краткие выжимки прошлых действий (результаты `shell`, squashed patches).
2. **`<file_context status="PINNED">`**: Критические интерфейсы, "прибитые" командой `pin`. Не подлежат удалению из контекста.
3. **`<file_context status="RECENTLY_MODIFIED">`**: Файлы, которые агент только что изменил.
4. **`<file_context status="READ_ONLY">`**: Фоновый контекст (вытесняется первым при нехватке токенов).
5. **`<file_target>`**: **(Positional Inversion)** — Целевой рабочий файл всегда помещается в самый *конец* промпта (ближе всего к attention heads модели при генерации ответа).

Если файл не влезает в лимит (`MAX_CONTEXT`), он заменяется на `<file_context path="..." status="OMITTED_OUT_OF_MEMORY" />`.

---

## 🧬 5. Движок мутаций: C-Native Fuzzy Patcher

Патчинг кода выполняется модулем `patcher_core.so` (написан на С).

**Почему C?**
LLM часто галлюцинируют с пробелами, табами и переносами строк (`\r\n` vs `\n`). Стандартный regex в Lua не справится. Наш C-алгоритм выполняет zero-allocation fuzzy matching, игнорируя whitespace-токены.

**The MUC Rule (Minimum Unchanged Context):**
Чтобы алгоритм точно нашел место для патча, агент ОБЯЗАН предоставлять 1-2 строки неизмененного кода вокруг удаляемого/изменяемого блока. Это называется MUC. Если совпадений будет несколько, сработает Circuit Breaker (`AMBIGUOUS MATCH`), и патч будет отклонен.

**Синтаксис патча:**

```xml
<cmd>patch:src/main.c
<<<<<<< SEARCH
    // Unchanged line
    int a = 1;
    // Unchanged line
=======
    // Unchanged line
    int a = 1;
    int b = 2; // New code
    // Unchanged line
>>>>>>> REPLACE
</cmd>

```

---

## 🛡️ 6. Defense in Depth: Безопасность и Anti-Hallucination

Instruction-Tuned модели (Qwen, Claude) обучены использовать теги вроде `<tool_call>` или `<function>`. Это ломает кастомные парсеры.

**Уровни защиты E-va:**

1. **Recency Injection**: В самый конец каждого промпта (непосредственно перед ответом модели) движок вклеивает блок `⚙️ ENGINE DIRECTIVES`, строго запрещающий использование `<tool_call>`.
2. **Parser Sanitization**: По принципу Postel's Law, `parser.lua` автоматически удаляет "мусорные" теги-обертки LLM до того, как state machine начнет извлекать команды `<cmd>`.
3. **Shell Escaping**: Все пути и аргументы, передаваемые в системный shell, экранируются через `utils.shell_quote` для защиты от Command Injection.
4. **Shell Circuit Breaker**: Если агент 3 раза подряд "ломает" билд (команда `make` или `test` возвращает non-zero exit code), E-va прерывает цикл и заставляет агента перечитать исходники.

---

## 🧰 7. Toolchain & Privilege Segregation

Инструменты разделены на категории. В `config.lua` выдавайте права агентам по принципу Least Privilege. Архитектору нужен `outline`, кодеру нужен `patch`.

| Инструмент | Категория | Описание |
| --- | --- | --- |
| `explore_tree` | Discovery | Читает директории (поддерживает глубину `path:depth`). |
| `outline` | Discovery | AST-like парсинг файла (вытаскивает сигнатуры функций через `ripgrep`). |
| `read_file` / `read_chunk` | Discovery | Загрузка файла в память (целиком или `start-end` строки). |
| `search` | Discovery | Быстрый полнотекстовый поиск по проекту (`rg --fixed-strings`). |
| `patch` | Action | Применение диффов (см. *Fuzzy Patcher*). |
| `create_file` | Action | Создание/перезапись файла. |
| `shell` | Action | Выполнение bash-команд (с таймаутами и отслеживанием exit codes). |
| `rollback` / `cleanup_baks` | Action | Откат файла к `.bak` версии / удаление бекапов. |
| `delegate_plan` | Control | Передача JSON-пайплайна следующему агенту. |
| `task_complete` | Control | Завершение текущего шага / стадии. |
| `pin` / `unpin` | Control | Блокировка файла в памяти (защита от вытеснения). |
| `ask_user` | Control | Приостановка пайплайна для вопроса живому человеку. |
| `trace_execution` | Advanced | eBPF-трассировка бинарника (требует kernel capabilities). |

---

## 🔌 8. Расширение фреймворка: Как написать свой инструмент

Архитектура позволяет добавлять инструменты за 2 минуты.
Все инструменты лежат в `tools/`.

**Шаг 1. Создайте файл `tools/my_tool.lua`:**

```lua
local utils = require("utils")

local function register(registry)
    -- registry.register(Имя, Описание, Пример_использования, Функция_обработчик)
    registry.register("my_tool", "Делает что-то полезное", "<cmd>my_tool:arg1</cmd>", function(args, ctx, agent_name)
        local arg = utils.trim(args)
        
        if arg == "" then
            return { output = "\n[ERROR]: Missing arguments." }
        end
        
        -- Вы можете взаимодействовать с контекстом памяти (ctx)
        -- ctx:add_file("path", "content")
        -- ctx.file_states["path"] = "RECENTLY_MODIFIED"

        return { 
            output = "\n[SYSTEM]: my_tool successfully executed with arg: " .. arg,
            signal = nil -- Верните "PIPELINE_NEXT_STAGE", если инструмент должен завершить текущую стадию
        }
    end)
end

return { register = register }

```

**Шаг 2. Зарегистрируйте его в `tools/init.lua`:**

```lua
local my_tool = require("tools.my_tool")
my_tool.register(registry)

```

**Шаг 3. Выдайте права агенту в `.e-va-conf/config.lua`:**

```lua
allowed_tools = { "read_file", "my_tool", "task_complete" }

```

Движок автоматически сгенерирует Manifest-документацию для этого инструмента и вклеит ее в системный промпт агента.


