-- agent.lua
-- Автономный агент для рефакторинга без привязки к Neovim
-- Usage: lua agent.lua <path/to/file> "<instruction>"

local config_module = require("config")
local llm_handler = require("llm_handler")
local utils = require("utils")
local patcher = require("patcher") -- Твой существующий модуль
local lfs = require("lfs")
local io = require("io")

-- Простая проверка аргументов (argv check)
local target_file = arg[1]
local instruction = arg[2]

if not target_file or not instruction then
    print("Usage: lua agent.lua <path/to/file> \"<instruction>\"")
    os.exit(1)
end

-- Загружаем конфиг
local cfg = config_module.get()
local project_root = cfg.PROJECT_ROOT or lfs.currentdir()

-- Проверяем существование файла (stat syscall)
local attr = lfs.attributes(target_file)
if not attr then
    print("Error: Target file not found: " .. target_file)
    os.exit(1)
end

-- Основной цикл агента
local function run_autonomous_agent(file_path, task)
    print("\n--- Starting Autonomous Agent ---")
    print("Target: " .. file_path)
    print("Task: " .. task)
    
    local conversation_history = {}
    
    -- 1. System Prompt (Задаем роль инженера)
    if cfg.SYSTEM_PROMPT then
        table.insert(conversation_history, { role = "system", content = cfg.SYSTEM_PROMPT })
    end

    -- 2. Читаем целевой файл (I/O Read)
    local content, err = utils.read_file_content(file_path)
    if not content then
        print("Critical Error: Cannot read file. " .. (err or ""))
        return
    end

    -- Формируем первый запрос
    local initial_prompt = string.format(
        "Task: %s\n\nTarget File: %s\nContent:\n```%s\n%s\n```\n\n" ..
        "If you need to analyze dependencies (imports/requires), request them using: 'read file `path/to/dependency`'. " ..
        "If you are ready to fix/refactor, provide the Unified Diff (patch).",
        task, file_path, utils.get_file_extension(file_path), content
    )
    
    table.insert(conversation_history, { role = "user", content = initial_prompt })

    local max_turns = 10 -- Дадим ему больше свободы для исследования зависимостей
    local current_turn = 0

    while current_turn < max_turns do
        current_turn = current_turn + 1
        print(string.format("\n[Turn %d] Thinking...", current_turn))

        -- Подготовка payload для запроса
        local request_data = {
            model = cfg.API_MODEL,
            messages = conversation_history,
            stream = false,
            options = {
            temperature = 0.0, -- Ставь 0.0 для кодинга (максимальная точность)
            top_k = 20,        -- Ограничивает выборку токенов (меньше бреда)
            top_p = 0.9,       -- Nucleus sampling
            num_ctx = 64000     -- Контекстное окно (важно для Qwen)
          }
        }

        -- Network I/O
        local response_data, err = llm_handler.send_request(request_data)
        if not response_data then
            print("Error: API Request failed: ", err)
            break
        end

        local response_text, think_text = llm_handler.extract_response_and_think_content(
            llm_handler.extract_response_text(response_data)
        )

        if response_text:match("<DONE>") then
            print("\n>>> AGENT: Task completed successfully. Exiting.")
            break
        end

        if not response_text then
            print("Error: Empty response from LLM.")
            break
        end

        -- Логируем "мысли" (если модель поддерживает Chain of Thought)
        if think_text then
            print("\n[DeepSeek Thought]:\n" .. think_text .. "\n")
        end
        
        -- Добавляем ответ в историю
        table.insert(conversation_history, { 
            role = "assistant", 
            content = (think_text and ("<think>"..think_text.."</think>\n") or "") .. response_text 
        })

        -- === АНАЛИЗ ДЕЙСТВИЙ (Decision Tree) ===

        -- Действие A: Применение патча
        local is_patch = llm_handler.is_patch_format(response_text)
        if is_patch then
            print("\n>>> Detected PATCH. Applying to filesystem...")
            
            -- Используем твой patcher.lua напрямую, минуя neovim
            -- Нам нужно собрать ext_utils, так как patcher их требует
            local patch_utils = {
                safe_os_execute = utils.safe_os_execute,
                write_file = utils.write_file,
                read_file_content = utils.read_file_content,
                join_path = utils.join_path
            }

            local pre_patch_content = content -- Запоминаем текущее состояние (которое мы читали в начале или обновили)
        
        -- Если переменная content устарела (из-за прошлых итераций), лучше перечитать:
            pre_patch_content = utils.read_file_content(file_path)

            local success, msg = patcher.apply_patch(
                file_path, 
                response_text, 
                cfg.PATCH_COMMAND, 
                cfg.TEMP_DIR, 
                patch_utils
            )

            print(msg) -- Результат патчинга

            if success then
              print(">>> SUCCESS: Patcher reported success. Verifying content changes...")
              
              -- 1. Читаем файл заново
              local new_content, err_r = utils.read_file_content(file_path)
              if not new_content then break end

              -- [[ NEW: CONTENT COMPARISON ]]
              if new_content == pre_patch_content then
                   print(">>> WARNING: File content is IDENTIAL after patch. The patch did nothing.")
                   table.insert(conversation_history, {
                      role = "user",
                      content = "The `patch` command reported success, but the file content did NOT change.\n" ..
                                "This means your patch was likely valid syntax but matched nothing (context mismatch).\n" ..
                                "Please REVIEW the file content again and provide a CORRECTED patch with proper context lines."
                  })
                  -- Не прерываем, даем шанс исправить
              else
                  -- Если контент изменился, ТОЛЬКО ТОГДА запускаем верификацию логики
                  table.insert(conversation_history, {
                      role = "user",
                      content = "The patch was applied and file changed. Here is the UPDATED file:\n" ..
                                "```" .. utils.get_file_extension(file_path) .. "\n" ..
                                new_content .. "\n" ..
                                "```\n\n" ..
                                "VERIFICATION: Does this code NOW match the instruction?\n" ..
                                "If YES: reply <DONE>\n" ..
                                "If NO: provide a new patch."
                  })
              end
              
          else
              -- (Старая логика FAIL)
              print(">>> FAIL: Patch rejected...")
              -- ...
          end
        -- Действие B: Запрос на чтение другого файла (Dependency resolution)
        else
            local requested_file = llm_handler.find_file_request(response_text)
            if requested_file then
                print("\n>>> Agent requested to read file: " .. requested_file)
                
                -- Пытаемся найти файл относительно корня проекта
                local abs_path = utils.join_path(project_root, requested_file)
                local dep_content, read_err = utils.read_file_content(abs_path)

                if dep_content then
                    print(">>> File read successfully. Sending context to Agent.")
                    table.insert(conversation_history, {
                        role = "user",
                        content = string.format(
                            "Content of `%s`:\n```%s\n%s\n```\nContinue your analysis.",
                            requested_file, utils.get_file_extension(requested_file), dep_content
                        )
                    })
                else
                    print(">>> Error reading dependency: " .. (read_err or "Unknown"))
                    table.insert(conversation_history, {
                        role = "user",
                        content = "Could not read file `" .. requested_file .. "`. Error: " .. (read_err or "File not found")
                    })
                end
            else
                -- Действие C: Просто болтовня (Chatting)
                print("\n[Agent says]: " .. response_text)
                print("\nNo action detected. Continuing loop...")
                -- Можно добавить прерывание или вопрос пользователю, но для автономии пусть продолжает
                table.insert(conversation_history, {
                    role = "user",
                    content = "Please proceed with the task. Provide a patch or request more files if needed."
                })
            end
        end
    end
end

-- Запуск
run_autonomous_agent(target_file, instruction)
