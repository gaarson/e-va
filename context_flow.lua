-- context_flow.lua
-- Модуль управления историей, контекстом, базой знаний и флоу выполнения команд.
-- Поддерживает декларативную конфигурацию и стратегии для разных моделей.

local M = {}
local utils = require("utils")
local json = require("JSON")
local registry = require("tool_registry")
local logger = require("logger")
local inspect = require("inspect")

-- ============================================================================
-- 1. ДЕФОЛТНАЯ КОНФИГУРАЦИЯ И СТРАТЕГИИ
-- ============================================================================
M.DEFAULT_CONFIG = {
    -- Хранение истории и состояния
    storage = {
        max_history_messages = 200,
        max_history_tokens = 160000,
        squash_threshold_messages = 150,
        squash_threshold_tokens = 50000,
        dedup_tool_outputs = true,
        include_pinned_in_recency = true,
        max_recent_tool_outputs = 5,
    },
    -- Сборка контекста (промпта)
    context_injection = {
        mode = "append_to_last_user", -- "separate_message" | "append_to_last_user" | "system_block"
        recency_block_enabled = true,
        search_digest_enabled = true,
        max_recency_tokens = 4000,
        max_search_digest_tokens = 2000,
    },
    -- Флоу выполнения команд
    command_flow = {
        strict_parsing = true,
        max_retries = 3,
        auto_squash_on_mutation = true,
        continuation_prompt = "[SYSTEM]: Continue your analysis. Execute the next command or ask a question if clarification is needed.",
        reinforcement_interval = 5, -- Каждые N ходов напоминаем о плане
        allow_consecutive_assistant = false, -- Некоторые API требуют чередования ролей
    },
    -- Оценка токенов
    token_estimation = {
        chars_per_token = 3.5,
        system_prompt_estimate = 6000,
        reserved_output = 5000,
    },
    -- Профили моделей (переопределяют настройки выше)
    model_profiles = {
        reasoning = {
            context_injection = { mode = "separate_message" },
            command_flow = { strict_parsing = true, max_retries = 5 },
            storage = { squash_threshold_tokens = 100000 }
        },
        coding = {
            context_injection = { mode = "append_to_last_user", max_recency_tokens = 6000 },
            command_flow = { auto_squash_on_mutation = true, reinforcement_interval = 3 },
            storage = { max_history_tokens = 120000 }
        },
        chat = {
            context_injection = { recency_block_enabled = false, search_digest_enabled = false },
            command_flow = { strict_parsing = false, max_retries = 2 },
            storage = { max_history_messages = 50, max_history_tokens = 40000 }
        }
    }
}

-- Стратегии обрезки истории
M.PRUNE_STRATEGIES = {
    fifo = function(history, limits)
        while #history > limits.max_history_messages do table.remove(history, 1) end
    end,
    fifo_assistant_first = function(history, limits)
        while #history > limits.max_history_messages do
            local idx = 1
            if history[idx] and history[idx].role == "user" then
                table.remove(history, idx)
            else
                table.remove(history, 1)
            end
        end
    end,
    squash_large_patches = function(history, limits, estimate_fn)
        local total = 0
        for _, m in ipairs(history) do total = total + estimate_fn(m.content) end
        if total > limits.max_history_tokens then
            for i = 1, #history - 5 do
                if history[i] and history[i].role == "assistant" then
                    local c = history[i].content or ""
                    if c:match("||| COMMAND |||\n(patch|create_file):") then
                        history[i].content = "[SYSTEM MEMORY: Previous code mutation squashed to save context.]"
                        total = total - estimate_fn(c) + estimate_fn(history[i].content)
                        if total <= limits.max_tokens then break end
                    end
                end
            end
        end
    end
}

-- Стратегии инъекции контекста
M.INJECTION_STRATEGIES = {
    separate_message = function(messages, recency, digest)
        local block = recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        table.insert(messages, { role = "user", content = block })
    end,
    append_to_last_user = function(messages, recency, digest)
        local block = recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        if block == "" then return end

        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                local content = messages[i].content
                
                -- Удаляем предыдущие динамические блоки, чтобы избежать накопления
                -- Примечание: в Lua 5.1 точка не ловит \n, поэтому используем (.|\n)
                content = content:gsub("<execution_plan>(.-)</execution_plan>", "")
                content = content:gsub("<last_actions>(.-)</last_actions>", "")
                content = content:gsub("<file_context[^>]->(.-)</file_context>", "")
                content = content:gsub("\n\n+", "\n\n")
                content = utils.trim(content)
                
                -- Собираем чистое сообщение + свежий блок контекста
                messages[i].content = (content ~= "" and content .. "\n\n" or "") .. block
                break
            end
        end
    end,
    system_block = function(messages, recency, digest)
        local block = "<system_context>\n" .. recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        block = block .. "\n</system_context>"
        table.insert(messages, 1, { role = "system", content = block })
    end
}

-- ============================================================================
-- 2. ИНИЦИАЛИЗАЦИЯ И КОНФИГУРАЦИЯ
-- ============================================================================
function M.new(flow_config, full_config)
    local self = setmetatable({}, { __index = M })
    self.config = full_config or {} -- Полная конфигурация проекта (для agent.lua и тулов)
    self.flow_config = utils.deep_merge(M.DEFAULT_CONFIG, flow_config or {}) -- Настройки контекстного потока
    local profile_name = self.config.context_profile
    if profile_name and self.flow_config.model_profiles[profile_name] then
        self.flow_config = utils.deep_merge(self.flow_config, self.flow_config.model_profiles[profile_name])
    end
    -- Внутреннее состояние
    self.task_summary = ""
    self.history = {}
    self.knowledge_base = {}
    self.file_states = {}
    self.pinned_files = {}
    self.search_history = {}
    self.thoughts = {}
    self.last_actions = {}
    self.turn_requested_files = {}
    self.promoted_files = {}

    self.recent_tool_outputs = {}
    self.global_access_counter = 0
    self.file_access_rank = {}
    self.execution_plan = {}
    self.current_task_index = 1
    self.handoff_memo = nil
    self.images = {}
    self.images_loaded = false
    self.test_failures = 0
    self.consecutive_recoveries = 0
    self.file_tree = nil
    return self
end

-- ============================================================================
-- 3. УПРАВЛЕНИЕ ИСТОРИЕЙ И БАЗОЙ ЗНАНИЙ
-- ============================================================================
function M:add_message(agent_name, role, content)
    self.history[agent_name] = self.history[agent_name] or {}
    table.insert(self.history[agent_name], { role = role, content = content })
    self:prune_history(agent_name)
end

function M:get_history(agent_name)
    return self.history[agent_name] or {}
end

function M:prune_history(agent_name)
    local history = self:get_history(agent_name)
    local limits = self.flow_config.storage
    local estimate = function(t) return math.ceil((#(t or "")) / self.flow_config.token_estimation.chars_per_token) end
    
    -- Применяем стратегии (можно расширять)
    M.PRUNE_STRATEGIES.fifo_assistant_first(history, limits)
    M.PRUNE_STRATEGIES.squash_large_patches(history, limits, estimate)
end

function M:squash_last_mutation(agent_name)
    if not self.flow_config.command_flow.auto_squash_on_mutation then return false end
    local history = self:get_history(agent_name)
    for i = #history, 1, -1 do
        local msg = history[i]
        if msg.role == "assistant" then
            local original = msg.content or ""
            local squashed = original:gsub("||| COMMAND |||\n(patch|create_file):([^%s\n]+)%s*\n.-||| END_COMMAND |||", 
                function(_, file_path) return string.format("\n[SYSTEM MEMORY: %s applied to '%s'.]\n", 
                    (file_path == "patch" and "Patch" or "File"), file_path or "unknown") end)
            squashed = utils.trim(squashed:gsub("\n\n+", "\n\n"))
            if original ~= squashed then
                history[i].content = squashed
                return true
            end
            break
        end
    end
    return false
end

function M:add_file(path, content)
    self.knowledge_base[path] = content
    self.file_states[path] = "READ"
    self.global_access_counter = self.global_access_counter + 1
    self.file_access_rank[path] = self.global_access_counter
end

function M:pin_file(path)
    if self.knowledge_base[path] then self.pinned_files[path] = true; return true end
    return false
end

function M:unpin_file(path)
    if self.pinned_files[path] then self.pinned_files[path] = nil; return true end
    return false
end

function M:add_tool_output(tool_name, output)
    if not output or output == "" then return end
    local max_len = 10000000
    local truncated = #output > max_len and output:sub(1, max_len) .. "\n...[TRUNCATED]" or output
    table.insert(self.recent_tool_outputs, { tool = tool_name, output = truncated })
    if #self.recent_tool_outputs > self.flow_config.storage.max_recent_tool_outputs then
        table.remove(self.recent_tool_outputs, 1)
    end
end

function M:track_requested_file(path)
    if path then self.turn_requested_files[path] = true end
end

function M:clear_turn_requested_files()
    self.turn_requested_files = {}
end

-- ============================================================================
-- 4. СБОРКА КОНТЕКСТА (ПРОМПТА)
-- ============================================================================
function M:build_context(agent_name, agent_cfg, available_tokens)
    local system_prompt = self:get_system_prompt(agent_cfg)
    local messages = { { role = "system", content = system_prompt } }
    local chat_buffer = {}
    local current_cost = 0
    local history = self:get_history(agent_name)
    local estimate = function(t) return math.ceil((#(t or "")) / self.flow_config.token_estimation.chars_per_token) end

    -- 1. Оцениваем размер обязательных блоков
    local recency = self:get_recency_block()
    local recency_cost = estimate(recency)
    local tools_manifest = require("tool_registry").generate_tool_manifest(agent_cfg.allowed_tools)
    local manifest_cost = estimate(tools_manifest)

    -- 2. Рассчитываем реальный бюджет на историю
    local overhead = recency_cost + manifest_cost + math.ceil(#system_prompt / self.flow_config.token_estimation.chars_per_token)
    local chat_budget = math.max(0, available_tokens - overhead - math.floor(available_tokens * 0.1)) -- 10% запас

    -- 3. Загружаем историю с конца
    for i = #history, 1, -1 do
        local msg = history[i]
        local cost = estimate(msg.content)
        if current_cost + cost < chat_budget then
            table.insert(chat_buffer, 1, { role = msg.role, content = msg.content })
            current_cost = current_cost + cost
        else break end
    end

    -- 4. Инъекция recency
    local inject_fn = M.INJECTION_STRATEGIES[self.flow_config.context_injection.mode] or M.INJECTION_STRATEGIES.append_to_last_user
    inject_fn(chat_buffer, recency, "")

    -- Добавляем handoff или initiation
    if #history == 0 then
        local init_msg = self.handoff_memo and 
            "[SYSTEM: HANDOFF MEMO]\n" .. self.handoff_memo or
            "[SYSTEM: INITIATION]\nReview context and proceed."
        table.insert(chat_buffer, { role = "user", content = init_msg })
    end
    
    -- Нормализация ролей для API (некоторые не любят system в середине)
    for _, msg in ipairs(chat_buffer) do
        local role = msg.role == "system" and "user" or msg.role
        table.insert(messages, { role = role, content = msg.content })
    end

    -- print(string.format("[DEBUG] Recency Block content: %s", recency)) 
    
    -- Инъекция изображений (OpenAI Format)
    if self.images_loaded and #self.images > 0 then
        local formatted_images = {}
        for _, img in ipairs(self.images) do
            table.insert(formatted_images, {
                type = "image_url",
                image_url = {
                    url = "data:" .. img.mime_type .. ";base64," .. img.base64_data
                }
            })
        end
        
        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                messages[i].content = {
                    { type = "text", text = messages[i].content },
                    unpack(formatted_images)
                }
                break
            end
        end
    end
    
    -- Фикс для API: если последний assistant, добавляем continuation
    if #messages > 1 and messages[#messages].role == "assistant" then
        table.insert(messages, { role = "user", content = self.flow_config.command_flow.continuation_prompt })
    end

    local tools_manifest = require("tool_registry").generate_tool_manifest(agent_cfg.allowed_tools)
    if tools_manifest and tools_manifest ~= "" then
        if #messages > 0 and messages[#messages].role == "user" then
            if type(messages[#messages].content) == "table" then
                -- Если последнее сообщение содержит изображения (мультимодальный формат), ищем текстовую часть
                for _, part in ipairs(messages[#messages].content) do
                    if part.type == "text" then
                        part.text = part.text .. "\n\n" .. tools_manifest
                        break
                    end
                end
            else
                -- Обычное текстовое сообщение
                messages[#messages].content = messages[#messages].content .. "\n\n" .. tools_manifest
            end
        else
            -- Если последнее сообщение не от user (например, assistant), создаем новое
            table.insert(messages, { role = "user", content = tools_manifest })
        end
    end
    
    local total_tokens = estimate(system_prompt) + current_cost + recency_cost + manifest_cost

    return {
        messages = messages,
        total_tokens = total_tokens,
        system_prompt = system_prompt,
        chat_buffer = chat_buffer
    }
end

function M:get_recency_block()
    local parts = {}
    -- System state
    -- if self.task_summary then table.insert(parts, string.format("<task_summary>%s</task_summary>", self.task_summary)) end
    if self.execution_plan and #self.execution_plan > 0 then
        table.insert(parts, "<execution_plan>" .. self:get_plan_text() .. "</execution_plan>")
    end
    if #self.last_actions > 0 then
        table.insert(parts, "<last_actions>" .. self:get_actions_text() .. "</last_actions>")
    end

    if self.flow_config.storage.include_pinned_in_recency then
        for path,_ in pairs(self.pinned_files) do
            if not self.turn_requested_files[path] and self.knowledge_base[path] then
                local content = self.knowledge_base[path]
                if self.promoted_files and self.promoted_files[path] then
                    local max_display_len = 200
                    if #content > max_display_len then
                        content = content:sub(1, max_display_len) .. "\n...[TRUNCATED: Full content moved to conversation history]..."
                    end
                end
                table.insert(parts, string.format("<file_context path=\"%s\" status=\"PINNED\">\n%s\n</file_context>",
                    path, content:gsub("\n", "\n\t")))
            end
        end
    end

    return table.concat(parts, "\n")
end

function M:get_search_digest(max_tokens)
    if not next(self.search_history) then return "" end
    local buf = {"\n=== SEARCH DIGEST ==="}
    local tokens = 0
    local div = self.flow_config.token_estimation.chars_per_token
    for q, res in pairs(self.search_history) do
        table.insert(buf, "--- Query: " .. q .. " ---")
        for line in res:gmatch("[^\r\n]+") do
            local clean = line:match("[:-]%d+[:-]%s*(.+)$") or line
            clean = clean:gsub("^%s+", ""):gsub("%s+", " ")
            if clean ~= "" then
                table.insert(buf, clean)
                tokens = tokens + math.ceil(#clean / div)
                if tokens >= max_tokens then
                    table.insert(buf, "... [TRUNCATED] ...")
                    return table.concat(buf, "\n")
                end
            end
        end
    end
    return table.concat(buf, "\n")
end

function M:get_system_prompt(agent_cfg)
    local prompt_text = self:load_prompt(agent_cfg.prompt_file)
    -- local tools_manifest = require("tool_registry").generate_tool_manifest(agent_cfg.allowed_tools)
    local directives = self:get_engine_directives(agent_cfg)
    return prompt_text .. "\n" .. directives
end

function M:get_engine_directives(agent_cfg)
    local has_delegate = false
    local has_complete = false
    for _, t in ipairs(agent_cfg.allowed_tools or {}) do
        if t == "delegate_plan" or t == "*" then has_delegate = true end
        if t == "task_complete" or t == "*" then has_complete = true end
    end
    local rule = has_delegate and has_complete and "Use `task_complete` to advance." or
                 has_delegate and "Use `delegate_plan` to advance." or
                 has_complete and "Use `task_complete` to finish." or "Analyze and respond."
    return string.format([[
==================================================
ENGINE DIRECTIVES:
1. PIPELINE: %s
2. ONE COMMAND PER TURN. Use batch tools if needed.
==================================================]], rule)
end

function M:load_prompt(path)
    if not path then return "You are an AI assistant." end
    local paths = {
        self.config.PROJECT_ROOT .. "/.e-va-conf/" .. path,
        self.config.PROJECT_ROOT .. "/" .. path,
        os.getenv("AGENT_HOME") .. "/" .. path
    }
    for _, p in ipairs(paths) do
        local c = utils.read_file_range(p)
        if c then return c end
    end
    return "You are an AI assistant."
end

function M:get_plan_text()
    if not self.execution_plan or #self.execution_plan == 0 then return "" end
    local t = "\n=== EXECUTION PLAN ===\n"
    for i, task in ipairs(self.execution_plan) do
        local mark = (i < self.current_task_index) and "[x]" or (i == self.current_task_index) and "[>]" or "[ ]"
        t = t .. string.format("%s Step %d: %s -> %s\n", mark, i, tostring(task.file or "?"), tostring(task.instruction or "?"))
    end return t end

function M:get_actions_text()
    if #self.last_actions == 0 then return "" end
    local t = "\n=== LAST ACTIONS ===\n"
    for _, a in ipairs(self.last_actions) do t = t .. string.format("- %s: %s\n", a.type, a.summary) end
    return t
end

-- ============================================================================
-- 5. ФЛОУ ВЫПОЛНЕНИЯ КОМАНД
-- ============================================================================
function M:process_turn_response(agent_name, raw_content, executor)
    local cmd, parse_err = executor:parse_command(raw_content)

    -- 1. Нет команды -> разговор
    if not cmd then
        self:add_message(agent_name, "assistant", utils.trim(raw_content))
        return { type = "CONVERSATION", hint = parse_err }
    end
    
    -- 2. Валидация
    local valid, val_err = executor:validate_command(cmd)
    if not valid then
        self.consecutive_recoveries = (self.consecutive_recoveries or 0) + 1
        if self.consecutive_recoveries >= self.flow_config.command_flow.max_retries then
            return { type = "ERROR", message = "Validation failed after " .. self.flow_config.command_flow.max_retries .. " attempts." }
        end
        return { type = "RETRY", message = string.format("Command rejected: %s. Output exactly one valid command.", val_err) }
    end

    -- 3. Выполнение
    -- print(inspect(self))
    -- print(inspect(self))
    local res = registry.execute(cmd, self, agent_name)
    local tool_name = cmd:match("^([^:]+)")
    -- Сохраняем ответ ассистента (обрезанный если была команда)
    local hist_content = raw_content
    if cmd:match("||| COMMAND |||") then
        local idx = raw_content:find("||| COMMAND |||")
        hist_content = raw_content:sub(1, idx - 1)
    end

    local trimmed_hist = utils.trim(hist_content)
    if trimmed_hist ~= "" then
        self:add_message(agent_name, "assistant", trimmed_hist)
    end
    -- Если ответ был только командой, добавляем системный маркер, чтобы сохранить чередование ролей
    if trimmed_hist == "" and cmd then
        self:add_message(agent_name, "assistant", "[SYSTEM: Executing command without additional reasoning]")
    end

    if self.flow_config.command_flow.auto_squash_on_mutation then
        self:squash_last_mutation(agent_name)
    end
    -- Добавляем результат в историю как user/system
    if res.output then
        local sanitized_output = utils.sanitize_for_json(res.output)
        self:add_message(agent_name, "user", sanitized_output)
    end
    return { type = res.signal == "PIPELINE_NEXT_STAGE" and "COMPLETED" or "EXECUTED",
             tool = tool_name, output = res.output, signal = res.signal }
end

-- ============================================================================
-- 6. СОХРАНЕНИЕ/ВОССТАНОВЛЕНИЕ СОСТОЯНИЯ
-- ============================================================================
function M:snapshot()
    return json:encode({
        knowledge_base = self.knowledge_base,
        file_access_rank = self.file_access_rank,
        global_access_counter = self.global_access_counter,
        file_states = self.file_states,
        search_history = self.search_history,
        history = self.history,
        thoughts = self.thoughts,
        execution_plan = self.execution_plan,
        current_task_index = self.current_task_index,
        promoted_files = self.promoted_files,
        pinned_files = self.pinned_files,
        last_actions = self.last_actions,
        handoff_memo = self.handoff_memo,
        test_failures = self.test_failures,
        turn_requested_files = self.turn_requested_files
    })
end

function M:load_from_snapshot(json_str)
    local ok, state = pcall(function() return json:decode(json_str) end)
    if not ok or not state then return false, "Corrupted JSON" end
    self.knowledge_base = state.knowledge_base or {}
    self.file_access_rank = state.file_access_rank or {}
    self.global_access_counter = state.global_access_counter or 0
    self.file_states = state.file_states or {}
    self.search_history = state.search_history or {}
    self.history = state.history or {}
    self.thoughts = state.thoughts or {}
    self.execution_plan = state.execution_plan or {}
    self.current_task_index = state.current_task_index or 1
    self.pinned_files = state.pinned_files or {}
    self.last_actions = state.last_actions or {}
    self.handoff_memo = state.handoff_memo
    self.test_failures = state.test_failures or 0
    self.turn_requested_files = state.turn_requested_files or {}
    self.promoted_files = state.promoted_files or {}

    return true
end

function M:reset()
    self.task_summary = ""
    self.history = {}
    self.knowledge_base = {}
    self.file_states = {}
    self.pinned_files = {}
    self.search_history = {}
    self.thoughts = {}
    self.last_actions = {}
    self.turn_requested_files = {}
    self.promoted_files = {}
    self.recent_tool_outputs = {}
    self.global_access_counter = 0
    self.file_access_rank = {}
    self.execution_plan = {}
    self.current_task_index = 1
    self.handoff_memo = nil
    self.images = {}
    self.images_loaded = false
    self.test_failures = 0
    self.consecutive_recoveries = 0
    self.file_tree = nil
end

-- ============================================================================
-- 7. HANDOFF MEMO & STAGE TRANSITION
-- ============================================================================
function M:generate_handoff_memo(agent_name, agent_cfg)
    local cfg = self.config.HANDOFF or {}
    local sections = cfg.memo_sections or { "execution_plan", "decisions", "files_modified", "remaining_tasks" }
    local max_tokens = cfg.max_memo_tokens or 4000
    local div = self.flow_config.token_estimation.chars_per_token
    local parts = {}
    local tokens = 0
    
    table.insert(parts, string.format("<handoff_memo agent=\"%s\">", agent_name))
    
    for _, sec in ipairs(sections) do
        if sec == "execution_plan" then
            local plan_text = self:get_plan_text()
            if plan_text ~= "" then
                table.insert(parts, "<execution_plan>" .. plan_text .. "</execution_plan>")
            end
        elseif sec == "decisions" or sec == "last_actions" then
            local actions_text = self:get_actions_text()
            if actions_text ~= "" then
                table.insert(parts, "<decisions>" .. actions_text .. "</decisions>")
            end
        elseif sec == "files_modified" then
            local modified = {}
            for path, state in pairs(self.file_states) do
                if state == "MODIFIED" or state == "CREATED" then
                    table.insert(modified, path)
                end
            end
            if #modified > 0 then
                table.insert(parts, "<files_modified>" .. table.concat(modified, ", ") .. "</files_modified>")
            end
        elseif sec == "remaining_tasks" then
            if self.execution_plan and #self.execution_plan > 0 then
                local remaining = {}
                for i = self.current_task_index, #self.execution_plan do
                    table.insert(remaining, string.format("Step %d: %s -> %s", i, self.execution_plan[i].file, self.execution_plan[i].instruction))
                end
                if #remaining > 0 then
                    table.insert(parts, "<remaining_tasks>" .. table.concat(remaining, "\n") .. "</remaining_tasks>")
                end
            end
        elseif sec == "knowledge_base_keys" then
            local keys = {}
            for path, _ in pairs(self.knowledge_base) do
                table.insert(keys, path)
            end
            if #keys > 0 then
                table.insert(parts, "<knowledge_base_keys>" .. table.concat(keys, ", ") .. "</knowledge_base_keys>")
            end
        elseif sec == "pinned_files" then
            local pins = {}
            for path, _ in pairs(self.pinned_files) do
                table.insert(pins, path)
            end
            if #pins > 0 then
                table.insert(parts, "<pinned_files>" .. table.concat(pins, ", ") .. "</pinned_files>")
            end
        elseif sec == "agent_summary" then
            table.insert(parts, "<agent_summary>[PROMPT: Please summarize your work in this stage]</agent_summary>")
        end
        
        tokens = tokens + math.ceil(#sec / div)
        if tokens >= max_tokens then break end
    end
    
    table.insert(parts, "</handoff_memo>")
    return table.concat(parts, "\n")
end

function M:clear_history_for_stage(strategy)
    if strategy == "none" or strategy == nil then return end
    
    if strategy == "full" then
        self.history = {}
        self.thoughts = {}
        self.last_actions = {}
        self.recent_tool_outputs = {}
        self.turn_requested_files = {}
    elseif strategy == "per_stage" then
        local keep_count = 10
        for agent_name, msgs in pairs(self.history) do
            if #msgs > keep_count then
                self.history[agent_name] = { unpack(msgs, #msgs - keep_count + 1, #msgs) }
            end
        end
        self.thoughts = {}
        self.recent_tool_outputs = {}
        self.turn_requested_files = {}
    end
end

function M:set_handoff_memo(memo)
    self.handoff_memo = memo
end

function M:sync_files()
    local updated_files = {}
    local root = self.config.PROJECT_ROOT or "."
    for path, old_content in pairs(self.knowledge_base) do
        local full_path = root .. "/" .. path
        local new_content = utils.read_file_range(full_path)
        if new_content and new_content ~= old_content then
            self.knowledge_base[path] = new_content
            table.insert(updated_files, path)
        end
    end
    return updated_files
end

function M:load_images(dir_path)
    if not dir_path or dir_path == "" then
        self.images = {}
        self.images_loaded = false
        return
    end
    self.images = utils.load_images_from_dir(dir_path)
    self.images_loaded = (#self.images > 0)
end

function M:update_summary(new_summary)
    self.task_summary = utils.trim(new_summary)
    self:add_action("SUMMARY_UPDATE", "Updated task summary")
end

function M:add_action(action_type, summary)
    table.insert(self.last_actions, { type = action_type, summary = summary })
    if #self.last_actions > 10 then table.remove(self.last_actions, 1) end
end

function M:get_file_context(file_info)
    local content = self.knowledge_base[file_info.path]
    if not content then return "" end
    local raw_lines = utils.read_lines_raw(content)
    local content_display = table.concat(raw_lines, "\n")
    local indented_content = "\t" .. content_display:gsub("\n", "\n\t")
    local status = "READ_ONLY"
    if file_info.is_target then status = "TARGET"
    elseif file_info.is_pinned then status = "PINNED"
    elseif file_info.is_modified then status = "RECENTLY_MODIFIED" end
    return string.format("\n<file_context path=\"%s\" status=\"%s\">\n\n%s\n\n</file_context>\n",
        file_info.path, status, indented_content)
end

function M:touch_file(path)
    if not path or not self.knowledge_base[path] then return end
    self.global_access_counter = self.global_access_counter + 1
    self.file_access_rank[path] = self.global_access_counter
end

function M:has_searched(query) return self.search_history[query] ~= nil end
function M:add_search_result(query, result) self.search_history[query] = result end

function M:estimate_tokens(text)
    if not text then return 0 end
    local divisor = self.flow_config.token_estimation.chars_per_token or 3.5
    return math.ceil(#text / divisor)
end

function M:get_recent_thoughts_text()
    if not self.thoughts or #self.thoughts == 0 then return "" end
    local text = "\n=== RECENT THOUGHTS ===\n"
    local start_idx = math.max(1, #self.thoughts - 140)
    for i = start_idx, #self.thoughts do
        text = text .. string.format("-----\n%s\n", self.thoughts[i].content)
    end
    return text
end

-- ============================================================================
-- ДОПОЛНИТЕЛЬНЫЕ МЕТОДЫ (Паритет с legacy context/init.lua)
-- ============================================================================
function M:optimize_context(instructions)
    if type(instructions) ~= "table" then return end
    if instructions.remove_file then
        self.knowledge_base[instructions.remove_file] = nil
        self.file_states[instructions.remove_file] = nil
        self.file_access_rank[instructions.remove_file] = nil
        self:add_action("CONTEXT_OPTIMIZATION", "Removed file from memory: " .. instructions.remove_file)
    end
    if instructions.pin_file then self:pin_file(instructions.pin_file) end
    if instructions.unpin_file then self:unpin_file(instructions.unpin_file) end
    if instructions.update_summary then self:update_summary(instructions.update_summary) end
    if type(instructions.remove_files) == "table" then
        for _, path in ipairs(instructions.remove_files) do
            self.knowledge_base[path] = nil; self.file_states[path] = nil; self.file_access_rank[path] = nil
            self:add_action("CONTEXT_OPTIMIZATION", "Removed file from memory: " .. path)
        end
    end
    if type(instructions.pin_files) == "table" then
        for _, path in ipairs(instructions.pin_files) do self:pin_file(path) end
    end
    if type(instructions.unpin_files) == "table" then
        for _, path in ipairs(instructions.unpin_files) do self:unpin_file(path) end
    end
end

function M:drop_last_message(agent_name)
    local history = self:get_history(agent_name)
    if #history > 0 then table.remove(history); return true end
    return false
end

function M:replace_last_assistant_message(agent_name, new_content)
    local history = self:get_history(agent_name)
    for i = #history, 1, -1 do
        if history[i].role == "assistant" then history[i].content = new_content; return true end
    end
    return false
end

function M:add_thought(turn, thought_text)
    self.thoughts = self.thoughts or {}
    local clean = utils.trim(thought_text)
    if clean == "" then return end
    table.insert(self.thoughts, { turn = turn, content = clean })
end

function M:get_thoughts_digest()
    if not self.thoughts or #self.thoughts == 0 then return "" end
    local out = {"\n=== AGENT RECENT THOUGHTS ==="}
    for _, th in ipairs(self.thoughts) do table.insert(out, th.content) end
    return table.concat(out, "\n")
end

function M:get_memory_block(max_tokens)
    max_tokens = max_tokens or 10000
    local current_tokens = 0
    local memory_parts = {}
    if next(self.pinned_files) then
        local pinned_text = "\n=== PINNED FILES ===\n"
        for path, _ in pairs(self.pinned_files) do pinned_text = pinned_text .. string.format("- %s\n", path) end
        local cost = self:estimate_tokens(pinned_text)
        if current_tokens + cost < max_tokens then table.insert(memory_parts, pinned_text); current_tokens = current_tokens + cost end
    end
    local changes_text = self:get_changes_summary()
    local cost = self:estimate_tokens(changes_text)
    if current_tokens + cost < max_tokens then table.insert(memory_parts, changes_text); current_tokens = current_tokens + cost end
    local insights_text = self:get_insights_summary()
    cost = self:estimate_tokens(insights_text)
    if current_tokens + cost < max_tokens then table.insert(memory_parts, insights_text); current_tokens = current_tokens + cost end
    return table.concat(memory_parts, "\n")
end

function M:get_report(agent_name)
    local search_summary = ""
    local count = 0
    for _,_ in pairs(self.search_history) do count = count + 1 end
    if count > 0 then search_summary = string.format("\n## SEARCH HISTORY\n(Cached %d queries)\n", count) end
    local tree_content = self.file_tree or "(empty)"
    if #tree_content > 30000 then
        tree_content = tree_content:sub(1, 30000) .. "\n... [TREE TRUNCATED - USE ||| COMMAND |||\nexplore_tree:path:depth\n||| END_COMMAND ||| TO NAVIGATE]"
    end
    local tree_block = string.format("## PROJECT STRUCTURE (Current View)\n```text\n%s\n```\n", tree_content)
    return string.format("# PROJECT CONTEXT\nRoot: %s\n---\n%s%s", self.flow_config.PROJECT_ROOT, tree_block, search_summary)
end

function M:should_squash(agent_name)
    local history = self:get_history(agent_name)
    local limits = self.flow_config.storage
    if #history > limits.squash_threshold_messages then return true end
    local total_tokens = 0
    for _, msg in ipairs(history) do total_tokens = total_tokens + self:estimate_tokens(msg.content) end
    if total_tokens > limits.squash_threshold_tokens then return true end
    return false
end

function M:build_system_state_xml()
    local xml = "<system_state>"
    if self.task_summary and self.task_summary ~= "" then
        xml = xml .. "\n  <task_summary>\t" .. self.task_summary:gsub("\n", "\n\t") .. "\n  </task_summary>"
    end
    if self.execution_plan and #self.execution_plan > 0 then
        xml = xml .. "\n  <execution_plan>\t" .. self:get_plan_text():gsub("\n", "\n\t") .. "\n  </execution_plan>"
    end
    if #self.last_actions > 0 then
        xml = xml .. "\n  <last_actions>\t" .. self:get_actions_text():gsub("\n", "\n\t") .. "\n  </last_actions>"
    end
    return xml .. "\n</system_state>"
end

function M:get_recency_tool_outputs()
    if not self.recent_tool_outputs or #self.recent_tool_outputs == 0 then return "" end
    local parts = {"\n<recent_tool_outputs>"}
    for _, tool_out in ipairs(self.recent_tool_outputs) do
        table.insert(parts, string.format("\n  <tool_output name=\"%s\">\n%s\n  </tool_output>", tool_out.tool, (tool_out.output or ""):gsub("\n", "\n  ")))
    end
    table.insert(parts, "\n</recent_tool_outputs>")
    return table.concat(parts)
end

function M:get_image_content_parts()
    if not self.images or #self.images == 0 then return {} end
    local parts = {}
    for _, img in ipairs(self.images) do
        table.insert(parts, { type = "image_url", image_url = { url = "data:" .. img.mime_type .. ";base64," .. img.base64_data } })
    end
    return parts
end

function M:get_changes_summary()
    local text = "\n=== CHANGES SUMMARY ===\n"
    for path, state in pairs(self.file_states) do
        if state == "RECENTLY_MODIFIED" then text = text .. string.format("- %s: modified\n", path) end
    end
    return text
end

function M:get_insights_summary()
    if not next(self.search_history) then return "" end
    local text = "\n=== SEARCH INSIGHTS ===\n"
    for query, result in pairs(self.search_history) do
        local lines = {}
        for line in result:gmatch("[^\r\n]+") do
            local pure = line:match("[:-]%d+[:-]%s*(.+)$") or line
            local compressed = pure:gsub("^%s+", ""):gsub("%s+", " ")
            if compressed ~= "" then table.insert(lines, compressed) end
        end
        text = text .. string.format("- %s: %s\n", query, table.concat(lines, "; "))
    end
    return text
end

function M:get_handoff_files()
    local files_to_pass = {} -- 1. Инициализируем таблицу
    local max_files = self.config.HANDOFF.max_knowledge_base_files or 50 -- 2. Берем лимит из конфига

    -- 1. Файлы из плана (приоритетные)
    if self.execution_plan then
        for _, task in ipairs(self.execution_plan) do
            if task.file then
                local rel_path = utils.normalize_path(self.config.PROJECT_ROOT, task.file)
                if self.knowledge_base[rel_path] then
                    files_to_pass[rel_path] = true
                end
            end
        end
    end
    -- 2. Зафиксированные файлы
    if self.config.HANDOFF.pass_pinned_files then
        for path, _ in pairs(self.pinned_files) do
            if self.knowledge_base[path] then
                files_to_pass[path] = true
            end
        end
    end
    -- 3. Запрошенные файлы
    if self.config.HANDOFF.pass_requested_files then
        for path, _ in pairs(self.turn_requested_files) do
            if self.knowledge_base[path] then
                files_to_pass[path] = true
            end
        end
    end
    -- 4. Остальные файлы из базы знаний (если нужно)
    if self.config.HANDOFF.pass_knowledge_base then
        for path, _ in pairs(self.knowledge_base) do
            if not files_to_pass[path] then
                files_to_pass[path] = true
                if #files_to_pass >= max_files then break end
            end
        end
    end
    return files_to_pass
end

-- НОВЫЙ: Метод для инъекции файлов в контекст следующего этапа
function M:inject_handoff_files(agent_name)
    local files_to_pass = self:get_handoff_files()
    if not next(files_to_pass) then return end
    local parts = {}
    local history = self:get_history(agent_name)
    
    for path, _ in pairs(files_to_pass) do
        local content = self.knowledge_base[path]
        if content then
            -- Проверка: не был ли файл уже добавлен в историю на этом этапе
            local is_in_history = false
            for _, msg in ipairs(history) do
                if msg.content and string.find(msg.content, path, 1, true) then -- true = plain search
                    is_in_history = true
                    break
                end
            end
            
            if not is_in_history then
                local status = "READ_ONLY"
                if self.pinned_files[path] then status = "PINNED"
                elseif self.file_states[path] == "RECENTLY_MODIFIED" then status = "RECENTLY_MODIFIED" end
                table.insert(parts, string.format(
                    "<file_context path=\"%s\" status=\"%s\">\n%s\n</file_context>",
                    path, status, content:gsub("\n", "\n\t")
                ))
            end
        end
    end
    if #parts > 0 then
        local block = "\n[HANDOFF CONTEXT - Files from previous stage]\n" .. table.concat(parts, "\n\n")
        self:add_message(agent_name, "user", block)
    end
end

function M:get_execution_plan_text() return self:get_plan_text() end
function M:get_last_actions_text() return self:get_actions_text() end

return M
