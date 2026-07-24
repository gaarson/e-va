# Документация по Busted и Luacov для проекта E-va

> **Собрано из официальных источников:**
> - [Busted GitHub](https://github.com/Olivine-Labs/busted)
> - [Busted Official Docs](https://lunarmodules.github.io/busted/)
> - [LuaCov GitHub](https://github.com/lunarmodules/luacov)
> - [LuaCov Official Docs](https://lunarmodules.github.io/luacov/)

**Версии:**
- **Lua:** 5.1.5
- **Busted:** совместим с Lua ≥ 5.1
- **Luacov:** совместим с Lua ≥ 5.1

---

## Часть 1: Busted — Фреймворк тестирования для Lua

### 📖 Обзор

**Busted** — это фреймворк модульного тестирования для Lua, ориентированный на простоту использования. Поддерживает **Lua ≥ 5.1**, **LuaJIT ≥ 2.0.0** и MoonScript.

Тесты пишутся естественно и читаются как спецификации. Можно цеплять ассерты и отрицания (например, `assert.is_not.equal`). Группируйте тесты с помощью `describe`, добавляйте теги для запуска произвольных групп тестов.

Расширяемая библиотека ассертов позволяет создавать собственные функции проверки. Модульная система вывода поддерживает pretty/plain терминальный вывод, JSON (с потоковой передачей и без) и TAP-совместимый вывод для CI-серверов.

### 📦 Установка

```bash
# Через Luarocks
luarocks install busted

# Или из исходников
git clone https://github.com/Olivine-Labs/busted.git
cd busted
luarocks make
```

### 🚀 Базовое использование

#### Структура теста

```lua
describe("Мой модуль", function()
  describe("должен работать корректно", function()
    it("должен быть простым в использовании", function()
      assert.truthy("Да.")
    end)

    it("должен иметь много функций", function()
      -- Глубокое сравнение таблиц!
      assert.same({ table = "great" }, { table = "great" })

      -- Или проверка по ссылке!
      assert.is_not.equals({ table = "great" }, { table = "great" })

      assert.falsy(nil)
      assert.has_error(function() error("Wat") end, "Wat")
    end)

    it("должен предоставлять сокращения для частых операций", function()
      assert.are.unique({{ thing = 1 }, { thing = 2 }, { thing = 3 }})
    end)

    it("должен иметь моки и шпионов для функциональных тестов", function()
      local thing = require("thing_module")
      spy.on(thing, "greet")
      thing.greet("Hi!")

      assert.spy(thing.greet).was.called()
      assert.spy(thing.greet).was.called_with("Hi!")
    end)
  end)
end)
```

#### Запуск тестов

```bash
# Запустить все тесты в текущей директории
busted

# Запустить конкретный файл
busted test_spec.lua

# Запустить с подробным выводом
busted --verbose

# Запустить с покрытием кода (требует luacov)
busted --coverage
```

### 🔧 Командная строка (CLI)

```
Usage: busted [OPTIONS] [--] [ROOT-1 [ROOT-2 [...]]]

АРГУМЕНТЫ:
  ROOT                      Файл/папка с тестами. Папки обходятся
                            рекурсивно по шаблону --pattern. (по умолчанию: nil)

ОПЦИИ:
  --version                 Версия программы
  -p, --pattern=PATTERN     Шаблон Lua для файлов тестов (по умолчанию: _spec)
  --exclude-pattern=PATTERN Исключить файлы по шаблону Lua
  -e STATEMENT              Выполнить выражение STATEMENT
  -o, --output=LIBRARY      Библиотека вывода (по умолчанию: utfTerminal)
  -C, --directory=DIR       Директория перед запуском тестов (по умолчанию: ./)
  -f, --config-file=FILE    Загрузить конфиг из FILE
  -t, --tags=TAGS           Запускать только тесты с этими #тегами (по умолчанию: [])
  --exclude-tags=TAGS       Исключить тесты с этими #тегами
  --filter=PATTERN          Запускать только тесты, имена которых совпадают с шаблоном
  --filter-out=PATTERN      Исключить тесты по имени
  -m, --lpath=PATH          Префикс пути поиска Lua-модулей
  --cpath=PATH              Префикс пути поиска C-модулей
  -r, --run=RUN             Конфиг для запуска из .busted файла
  --repeat=COUNT            Повторять тесты N раз (по умолчанию: 1)
  --seed=SEED               Сид для случайной перестановки (по умолчанию: /dev/urandom)
  --lang=LANG               Язык сообщений об ошибках (по умолчанию: en)
  --loaders=NAME            Загрузчики файлов тестов (по умолчанию: lua,moonscript)
  --helper=PATH             Хелпер-скрипт, выполняемый перед тестами
  --lua=LUA                 Путь к интерпретатору Lua
  -c, --[no-]coverage       Анализ покрытия кода (требует LuaCov) (по умолчанию: off)
  -v, --[no-]verbose        Подробный вывод ошибок (по умолчанию: off)
  -s, --[no-]enable-sound   Звуковые уведомления через `say` (по умолчанию: off)
  -l, --list                Список всех тестов без запуска
  --[no-]lazy               Ленивый setup/teardown (по умолчанию: off)
  --[no-]auto-insulate      Изоляция файлов (по умолчанию: on)
  -k, --[no-]keep-going     Продолжать после ошибок (по умолчанию: on)
  -R, --[no-]recursive      Рекурсивный обход поддиректорий (по умолчанию: on)
  --[no-]shuffle            Случайный порядок файлов и тестов (по умолчанию: off)
  --[no-]suppress-pending   Скрыть `pending` тесты (по умолчанию: off)
  --[no-]defer-print        Вывод результатов после завершения всех тестов (по умолчанию: off)
```

### ⚙️ Конфигурационный файл `.busted`

Создайте файл `.busted` в корне проекта. Он автоматически загружается, если существует.

```lua
return {
  _all = {
    coverage = true
  },
  default = {
    verbose = true,
    ["suppress-pending"] = true
  },
  apiUnit = {
    tags = "api",
    ROOT = {"spec/unit"},
    verbose = true
  }
}
```

Запуск:
```bash
busted                    # использует default + _all
busted --run=apiUnit      # использует apiUnit + _all
```

> **Примечание:** Опции с невалидными символами Lua (тире) должны быть в квадратных скобках: `["suppress-pending"]`.

### 🏷️ Теги (Tags)

Добавляйте теги к блокам `describe` или `it`:

```lua
describe("#slow Мой медленный тест", function()
  it("#network Должен подключаться к API", function()
    -- ...
  end)
end)
```

Запуск по тегам:
```bash
busted --tags=slow
busted --exclude-tags=network
```

### 🎭 Моки и Шпионы (Mocks & Spies)

```lua
local thing = require("thing_module")

-- Шпион: отслеживает вызовы
spy.on(thing, "greet")
thing.greet("Hi!")
assert.spy(thing.greet).was.called()
assert.spy(thing.greet).was.called_with("Hi!")
assert.spy(thing.greet).was.called(1)  -- количество вызовов

-- Мок: заменяет поведение
mock = mock_new()
mock.return_value = "mocked result"
spy.on(thing, "compute")
thing.compute = mock
```

### 📝 Ассерты (Asserts)

| Ассерт | Описание |
|--------|----------|
| `assert.truthy(x)` | x не nil и не false |
| `assert.falsy(x)` | x равен nil или false |
| `assert.same(a, b)` | Глубокое сравнение таблиц |
| `assert.equals(a, b)` | Сравнение по ссылке (`==`) |
| `assert.is_not.equal(a, b)` | Отрицание: не равны по ссылке |
| `assert.has_error(fn, msg)` | fn вызывает ошибку с сообщением msg |
| `assert.are.unique(t)` | Все элементы таблицы уникальны |
| `assert.has_fields(obj, fields)` | Объект имеет указанные поля |
| `assert.matches(str, pattern)` | Строка совпадает с Lua-шаблоном |

Цепочка отрицаний: `assert.is_not.equal`, `assert.are_not.same`, `assert.has_no_error` и т.д.

### 🌐 Standalone режим

Можно запускать тесты без busted-исполнителя:

```lua
require 'busted.runner'()
```

### 🐳 Docker

```bash
# Предварительно собранный образ
docker pull ghcr.io/lunarmodules/busted:latest

# Запуск
docker run -v "$(pwd):/data" ghcr.io/lunarmodules/busted:latest

# Алиас
alias busted='docker run -v "$(pwd):/data" ghcr.io/lunarmodules/busted:latest'
```

---

## Часть 2: Luacov — Анализ покрытия кода для Lua

### 📖 Обзор

**LuaCov** — простой анализатор покрытия кода для Lua. При запуске скрипта с загруженным модулем `luacov` генерируется файл статистики с количеством выполнений каждой строки. Команда `luacov` обрабатывает этот файл и создаёт отчёт, показывающий непройденные пути кода — полезно для проверки эффективности тестового набора.

Написан на чистом Lua, без внешних зависимостей.

### 📦 Установка

```bash
# Через Luarocks
luarocks install luacov

# Для экспериментальных C-расширений (лучшая производительность)
luarocks install cluacov
```

### 🚀 Использование

#### Шаг 1: Сбор данных покрытия

Запустите скрипт с модулем `luacov`:

```bash
# Без изменения скрипта
lua -lluacov test.lua

# Или добавьте в начало скрипта
require("luacov")
```

После выполнения генерируется файл `luacov.stats.out`. Если файл уже существует, статистика **добавляется** к нему (удобно для серии запусков с разными параметрами). Чтобы начать заново — удалите файл.

#### Шаг 2: Генерация отчёта

```bash
luacov
```

По умолчанию ищет `luacov.stats.out` в текущей директории и выводит `luacov.report.out`.

Параметры:
```bash
luacov [-c=configfile] [filename...]
```

Файловые имена (Lua-паттерны) указывают, какие файлы включить в отчёт.

#### Пример отчёта

```
==============================================================================
test.lua
==============================================================================
 1 if 10 > 100 then
*0    print("Эта строка не выполнится.")
   else
 1    print("Hello, LuaCov!")
   end
```

> `*0` означает, что строка не была выполнена ни разу.

### 🔧 Игнорирование строк

Чтобы скрыть предупреждения о непокрытых строках, используйте inline-комментарии:

```lua
if SOME_DEBUG_CONDITION_THAT_IS_ALWAYS_FALSE_IN_TESTS then
   -- luacov: disable
   -- Эти строки не помечаются как непокрытые.
   -- luacov: enable
end
```

### ⏱️ Режим Tick (для демонов)

Если программа не завершается нормально (демон), используйте `luacov.tick`:

```bash
#!/usr/bin/env lua -lluacov.tick
```

Или добавьте в `.luacov`:

```lua
tick = true
```

### ⚙️ Конфигурация `.luacov`

Создайте файл `.luacov` в корне проекта — это Lua-скрипт, устанавливающий опции как глобальные переменные или возвращающий таблицу.

```lua
-- Пример: только модуль foo и его подмодули
modules = {
   ["foo"] = "src/foo/init.lua",
   ["foo.*"] = "src"
}
```

Полный список опций: [`luacov.defaults` documentation](https://lunarmodules.github.io/luacov/doc/modules/luacov.defaults.html)

#### HTML-отчёт

```lua
reporter = "html"
reportfile = "luacov.report.html"
```

### 🔌 Кастомные репортеры

| Репортер | Ссылка |
|----------|--------|
| Cobertura | https://github.com/britzl/luacov-cobertura |
| Coveralls | https://github.com/moteus/luacov-coveralls |
| Console | https://github.com/spacewander/luacov-console |
| LCOV | https://github.com/daurnimator/luacov-reporter-lcov |

---

## Часть 3: Интеграция Busted + Luacov

### Запуск тестов с покрытием

```bash
# Самый простой способ
busted --coverage

# Или вручную
lua -lluacov $(which busted)
luacov
```

### Типичный рабочий процесс

```bash
# 1. Удалить старые данные покрытия
rm -f luacov.stats.out

# 2. Запустить тесты с покрытием
busted --coverage --verbose

# 3. Посмотреть отчёт
cat luacov.report.out

# 4. Или HTML-отчёт (если настроен reporter = "html")
open luacov.report.html
```

### Пример `.busted` для проекта E-va

```lua
return {
  _all = {
    coverage = true,
    recursive = true,
    pattern = "_spec"
  },
  default = {
    verbose = true
  },
  quick = {
    exclude_tags = "slow"
  }
}
```

### Пример `.luacov` для проекта E-va

```lua
-- Исключить тестовые файлы из покрытия
exclude = { "test/", "spec/", "tests/" }

-- Включить только исходный код
include = { "src/" }

-- HTML-отчёт
reporter = "html"
reportfile = "coverage.html"
```

---

## 📚 Полезные ссылки

| Ресурс | Ссылка |
|--------|--------|
| Busted GitHub | https://github.com/Olivine-Labs/busted |
| Busted Docs | https://lunarmodules.github.io/busted/ |
| LuaCov GitHub | https://github.com/lunarmodules/luacov |
| LuaCov Docs | https://lunarmodules.github.io/luacov/ |
| LuaRocks | https://luarocks.org |
| Lua 5.1 Reference | https://www.lua.org/manual/5.1/ |

---

*Документация собрана из официальных источников GitHub и документации проектов Busted и LuaCov.*
