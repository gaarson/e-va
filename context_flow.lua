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
        stale_threshold_turns = 10, -- Pinned files not accessed in N turns are marked STALE and excluded from recency
    },
    -- Флоу выполнения команд
    command_flow = {
        strict_parsing = true,
        max_retries = 3,
        auto_squash_on_mutation = true,
        continuation_prompt = "ok",
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
-- Importance scoring for messages (higher = more important to keep)
M.IMPORTANCE_SCORES = {
    TASK_DESCRIPTION = 100,
    USER_QUESTION = 80,
    ASSISTANT_REASONING = 40,
    TOOL_OUTPUT = 20,
    SQUASHED_MUTATION = 5,
}
-- Helper: assign importance score to a message based on its content/role
local function _score_message(msg, idx, total)
    if not msg then return 0 end
    local role = msg.role or ""
    local content = msg.content or ""
    -- First 3 messages are always high priority (task initiation)
    if idx <= 3 then return 100 end
    -- Role-based scoring
    if role == "user" then
        -- User messages with questions or task descriptions are high priority
        if content:match("^TASK:") or content:match("^QUESTION:") or content:match("%?%s*$") then
            return M.IMPORTANCE_SCORES.USER_QUESTION
        end
        -- Tool outputs from user role are lower priority
        if content:match("^\\[OUTPUT\\]") or content:match("^\\[RESULT\\]") or content:match("^\\[SYSTEM") then
            return M.IMPORTANCE_SCORES.TOOL_OUTPUT
        end
        return M.IMPORTANCE_SCORES.USER_QUESTION
    elseif role == "assistant" then
        -- Assistant messages with commands are medium priority
        if content:match("||| COMMAND |||") then
            return M.IMPORTANCE_SCORES.ASSISTANT_REASONING + 10
        end
        -- Squashed mutations are low priority
        if content:match("^\\[SYSTEM MEMORY:") then
            return M.IMPORTANCE_SCORES.SQUASHED_MUTATION
        end
        return M.IMPORTANCE_SCORES.ASSISTANT_REASONING
    elseif role == "system" then
        return 60  -- System messages are moderately important
    end
    return 20  -- Default low priority
end
M.PRUNE_STRATEGIES = {
    fifo = function(history, limits)
        while #history > limits.max_history_messages do table.remove(history, 1) end
    end,
    -- IMPORTANCE-WEIGHTED PRUNING: Remove lowest-importance messages first
    importance_weighted = function(history, limits, estimate_fn)
        local max_msgs = limits.max_history_messages or 200
        while #history > max_msgs do
            -- Find the message with the lowest importance score (excluding first 3)
            local min_score = math.huge
            local min_idx = nil
            for i = 4, #history do  -- Skip first 3 messages (always preserved)
                local score = _score_message(history[i], i, #history)
                if score < min_score then
                    min_score = score
                    min_idx = i
                elseif score == min_score and min_idx then
                    -- Tie-break: remove older message (lower index)
                    if i < min_idx then
                        min_idx = i
                    end
                end
            end
            if min_idx and min_idx >= 4 then
                table.remove(history, min_idx)
            else
                break  -- No more removable messages
            end
        end
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
    end,
    -- EXTENDED SQUASH: Also squash large shell outputs and search results
    squash_large_outputs = function(history, limits, estimate_fn)
        local total = 0
        for _, m in ipairs(history) do total = total + estimate_fn(m.content) end
        if total > limits.max_history_tokens then
            for i = 1, #history - 5 do
                local msg = history[i]
                if not msg then break end
                local c = msg.content or ""
                if type(c) ~= "string" then c = tostring(c) end
                local original_len = #c
                
                -- Squash large shell outputs (>2KB) — using plain string find to avoid pattern errors
                if string.find(c, "[SHELL STDOUT/STDERR]:", 1, true) or string.find(c, "[SHELL STDOUT", 1, true) then
                    if original_len > 2048 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Shell output truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                -- Squash large search results (>1KB)
                elseif string.find(c, "[SEARCH RESULTS for '", 1, true) or string.find(c, "=== SEARCH DIGEST ===", 1, true) then
                    if original_len > 1024 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Search results truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                -- Squash large generic tool outputs (>2KB) — fix: use %[\ instead of \\[
                elseif c:match("^%[[A-Z]") then
                    if original_len > 2048 then
                        local line_count = select(2, c:gsub("\n", "\n"))
                        msg.content = string.format("[OUTPUT SUMMARIZED: Tool output truncated (%d lines, %d bytes)]", line_count, original_len)
                        total = total - estimate_fn(c) + estimate_fn(msg.content)
                    end
                end
                if total <= limits.max_history_tokens then break end
            end
        end
    end,
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
                -- FIX: Use ([\s\S]) instead of (.-) to correctly match newlines in Lua 5.1
                content = content:gsub("<execution_plan>([%s%S]*)</execution_plan>", "")
                content = content:gsub("<last_actions>([%s%S]*)</last_actions>", "")
                content = content:gsub("<file_context[^>]->([%s%S]*)</file_context>", "")
                content = content:gsub("\n\n+", "\n\n")
                content = utils.trim(content)

                -- Собираем чистое сообщение + свежий блок контекста
                messages[i].content = (content ~= "" and content .. "\n\n" or "") .. block
                break
            end
        end
    end,
    -- HYBRID STRATEGY: Inject dynamic context as a SEPARATE system message
    -- RIGHT BEFORE the last user message, keeping the original user message intact.
    -- This prevents task drift by preserving the original user intent.
    hybrid_insert = function(messages, recency, digest)
        local block = recency
        if digest and digest ~= "" then block = block .. "\n\n" .. digest end
        if block == "" then return end
        -- Find the last user message and insert system context right before it
        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                -- Insert as system message right before the last user message
                table.insert(messages, i, { role = "system", content = "[DYNAMIC CONTEXT]\n" .. block })
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
    self.last_sent_image_hashes = {}
    self.test_failures = 0
    self.consecutive_recoveries = 0
    self.file_tree = nil
    self.current_turn = 0 -- Tracks the current turn for staleness detection
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
    local agent_cfg = self.config.AGENTS[agent_name]
    local estimate = function(t) return self:estimate_tokens(t, agent_cfg) end
    -- Apply importance-weighted pruning (smarter than fifo)
    M.PRUNE_STRATEGIES.importance_weighted(history, limits, estimate)
    -- Squash large patches and outputs to save tokens
    M.PRUNE_STRATEGIES.squash_large_patches(history, limits, estimate)
    M.PRUNE_STRATEGIES.squash_large_outputs(history, limits, estimate)
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
    -- Track last accessed turn for staleness detection
    self.file_access_rank[path .. "_last_turn"] = self.current_turn
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
    local estimate = function(t) return self:estimate_tokens(t, agent_cfg) end
    -- 1. Оцениваем размер обязательных блоков
    local recency = self:get_recency_block()
    local recency_cost = estimate(recency)
    local tools_manifest = require("tool_registry").generate_tool_manifest(agent_cfg.allowed_tools, agent_cfg)
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

    -- Инъекция изображений (OpenAI Format) with deduplication
    local tokens_per_byte = (self.config.IMAGE_CONFIG and self.config.IMAGE_CONFIG.tokens_per_base64_byte) or 0.004

    if self.images_loaded and #self.images > 0 then
        -- Filter out images already sent (dedup by hash)
        local new_images = {}
        for _, img in ipairs(self.images) do
            local h = img.hash or ""
            if h == "" or not self.last_sent_image_hashes[h] then
                table.insert(new_images, img)
            end
        end

        if #new_images > 0 then
            local formatted_images = {}
            for _, img in ipairs(new_images) do
                table.insert(formatted_images, {
                    type = "image_url",
                    image_url = {
                        url = "data:" .. img.mime_type .. ";base64," .. img.base64_data
                    }
                })
            end

            local injected = false
            for i = 1, #messages do
                if messages[i].role == "user" then
                    messages[i].content = {
                        { type = "text", text = messages[i].content },
                        unpack(formatted_images)
                    }
                    injected = true
                    break
                end
            end

            -- EDGE CASE: if no user-role message found, prepend one
            if not injected then
                table.insert(messages, 1, {
                    role = "user",
                    content = {
                        { type = "text", text = "[SYSTEM: Images attached]" },
                        unpack(formatted_images)
                    }
                })
            end

            -- Update last_sent_image_hashes with newly sent images
            for _, img in ipairs(new_images) do
                local h = img.hash or ""
                if h ~= "" then self.last_sent_image_hashes[h] = true end
            end
        end
    end

    -- AUTO-PURGE removed: images now persist across turns (auto_purge_after_turn = false in config)
    -- Use M:purge_images() explicitly if you need to clear images

    -- Фикс для API: если последний assistant, добавляем continuation
    if #messages > 1 and messages[#messages].role == "assistant" then
        table.insert(messages, { role = "user", content = self.flow_config.command_flow.continuation_prompt })
    end

    -- TOKEN ESTIMATION: Count only NEW images (respecting dedup via last_sent_image_hashes)
    local total_image_tokens = 0
    if self.images_loaded and #self.images > 0 then
        for _, img in ipairs(self.images) do
            local h = img.hash or ""
            -- Only count images that will actually be sent (not already sent)
            if h == "" or not self.last_sent_image_hashes[h] then
                local b64_len = #(img.base64_data or "")
                -- OpenAI vision: low res (<50KB base64) = 85 tokens, high res = ~0.004 tokens/byte
                if b64_len < 50 * 1024 then
                    total_image_tokens = total_image_tokens + 85
                else
                    total_image_tokens = total_image_tokens + math.ceil(b64_len * tokens_per_byte)
                end
            end
        end
    end

    local total_tokens = estimate(system_prompt) + current_cost + recency_cost + manifest_cost + total_image_tokens

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
                    path, content))
            end
        end
    end

    return table.concat(parts, "\n")
end

function M:get_search_digest(max_tokens)
    local div = self.flow_config.token_estimation.chars_per_token
    local buf = {"\n=== SEARCH DIGEST ==="}
    local tokens = 0
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
    local tools_manifest = require("tool_registry").generate_tool_manifest(agent_cfg.allowed_tools, agent_cfg)
    local directives = self:get_engine_directives(agent_cfg)
    return prompt_text .. "\n" .. directives .. "\n" .. tools_manifest
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


    -- Multi-stage info

    local multi_stage_note = ""

    if agent_cfg.use_selective_multi_stage and agent_cfg.multi_stage_tools and #agent_cfg.multi_stage_tools > 0 then

        local tool_list = table.concat(agent_cfg.multi_stage_tools, ", ")

        multi_stage_note = string.format("\n3. MULTI-STAGE: Tools [%s] go through Intent->Generate->Review. Others execute directly.", tool_list)

    end


    return string.format("\n==================================================\nENGINE DIRECTIVES:\n1. PIPELINE: %s\n2. ONE COMMAND PER TURN. Use batch tools if needed.%s\n==================================================", rule, multi_stage_note)

end


	function M:load_prompt(path)
	    if not path then return "You are an AI assistant." end
	    local paths = {}
	    -- Support absolute paths: try directly first
	    if path:sub(1, 1) == "/" then
	        table.insert(paths, path)
	    end
	    table.insert(paths, self.config.PROJECT_ROOT .. "/.e-va-conf/" .. path)
	    table.insert(paths, self.config.PROJECT_ROOT .. "/" .. path)
	    local agent_home = os.getenv("AGENT_HOME")
	    if agent_home then table.insert(paths, agent_home .. "/" .. path) end
	    for _, p in ipairs(paths) do
	        local c = utils.read_file_range(p)
	        if c then return c end
	    end
	    return "You are an AI assistant."
	end

function M:get_plan_text()
  if not self.execution_plan or #self.execution_plan == 0 then return "" end
  local t = ""
  for i, task in ipairs(self.execution_plan) do
      local mark = (i < self.current_task_index) and "[x]" or (i == self.current_task_index) and "[>]" or "[ ]"
      t = t .. string.format("%s Step %d: %s -> %s\n", mark, i, tostring(task.file or "?"), tostring(task.instruction or "?"))
  end
  return t
end

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
        -- FIX: Treat truncation/format errors as RETRY, not CONVERSATION
        local is_retryable = parse_err and (
            parse_err:match("TRUNCATED") or 
            parse_err:match("MALFORMED_COMMAND") or 
            parse_err:match("empty")
        )
        
        if is_retryable then
            self.consecutive_recoveries = (self.consecutive_recoveries or 0) + 1
            if self.consecutive_recoveries >= self.flow_config.command_flow.max_retries then
                self:add_message(agent_name, "assistant", utils.trim(raw_content))
                return { type = "ERROR", message = "Command parsing failed after " .. self.flow_config.command_flow.max_retries .. " attempts." }
            end
            return { type = "RETRY", message = string.format("Command rejected: %s. Output exactly one complete command block.", parse_err) }
        end

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
    self.last_sent_image_hashes = {}
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
        local raw_images = utils.load_images_from_dir(dir_path)
        local max_bytes = (self.config.IMAGE_CONFIG and self.config.IMAGE_CONFIG.max_images_base64_bytes) or (4 * 1024 * 1024)
        local max_age_hours = (self.config.IMAGE_CONFIG and self.config.IMAGE_CONFIG.max_image_age_hours) or 24

        -- Filter by age: skip images older than max_age_hours
        local now = os.time()
        local age_seconds = max_age_hours * 3600
        local aged_filtered = {}
        for _, img in ipairs(raw_images) do
            local safe_path = utils.shell_quote(img.path)
            local mod_time = 0
            -- Try stat to get modification time
            local cmd = string.format("stat -c %%Y %s 2>/dev/null", safe_path)
            local p = io.popen(cmd)
            if p then
                local t = p:read("*l")
                p:close()
                if t then mod_time = tonumber(t) or 0 end
            end
            if mod_time > 0 and (now - mod_time) > age_seconds then
                logger.info(string.format("[IMAGE] Skipping old image %s (age: %.1f hours)", img.path, (now - mod_time) / 3600))
            else
                table.insert(aged_filtered, img)
                -- Attach mod_time for sorting
                img.mod_time = mod_time
            end
        end

        -- Sort by modification time descending (newest first)
        table.sort(aged_filtered, function(a, b)
            local ta = a.mod_time or 0
            local tb = b.mod_time or 0
            return ta > tb
        end)

        local total_b64 = 0
        local filtered = {}
        for _, img in ipairs(aged_filtered) do
            local sz = #(img.base64_data or "")
            if total_b64 + sz <= max_bytes then
                table.insert(filtered, img)
                total_b64 = total_b64 + sz
            else
                logger.info(string.format("[IMAGE] Skipping image %s (%d bytes) — exceeds base64 budget %d", img.path, sz, max_bytes))
            end
        end

        self.images = filtered
        self.images_loaded = (#self.images > 0)
    end

    function M:add_image(base64_data, mime_type)
        if not base64_data or base64_data == "" then return end
        mime_type = mime_type or "image/png"
        local max_imgs = (self.config.IMAGE_CONFIG and self.config.IMAGE_CONFIG.max_images_per_turn) or 10
        if #self.images >= max_imgs then
            logger.warn(string.format("[IMAGE] Image cap reached (%d). Rejecting new image.", max_imgs))
            return
        end
        -- Compute inline hash for deduplication
        local sum = 0
        for i = 1, #base64_data do sum = (sum + string.byte(base64_data, i)) % 4294967295 end
        local hash = string.format("%08x_%d", sum, #base64_data)
        table.insert(self.images, { base64_data = base64_data, mime_type = mime_type, hash = hash })
        self.images_loaded = true
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
    local indented_content = content_display
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

-- ============================================================================
-- MULTI-STRATEGY TOKEN ESTIMATOR
-- Detects content type and uses appropriate divisors + structural overhead
-- ============================================================================
-- Per-text cache to avoid re-computing estimates on identical strings
local _token_estimate_cache = {}
local _cache_max_size = 1000
local function _cache_get(text)
    if not text then return nil end
    return _token_estimate_cache[text]
end
local function _cache_set(text, value)
    if not text then return end
    -- Evict oldest entry if cache is full (simple LRU-ish: just clear half)
    if next(_token_estimate_cache) then
        local count = 0
        for _ in pairs(_token_estimate_cache) do count = count + 1 end
        if count >= _cache_max_size then
            _token_estimate_cache = {}
        end
    end
    _token_estimate_cache[text] = value
end
-- Content type detection heuristics
local function _detect_content_type(text)
    local len = #text
    if len == 0 then return "empty" end
    local code_score = 0
    local xml_json_score = 0
    local prose_score = 0
    -- Code indicators
    if text:match("function%s+") or text:match("def%s+") or text:match("class%s+") or
       text:match("struct%s+") or text:match("import%s+") or text:match("require%(") or
       text:match("local%s+") or text:match("var%s+") or text:match("let%s+") or
       text:match("const%s+") or text:match("public%s+") or text:match("private%s+") or
       text:match("static%s+") or text:match("void%s+") or text:match("int%s+") or
       text:match("return%s+") or text:match("if%s+") or text:match("for%s+") or
       text:match("while%s+") or text:match("switch%s+") or text:match("case%s+") then
        code_score = code_score + 3
    end
    -- Code block markers
    local fence_count = 0
    for _ in text:gmatch("```") do fence_count = fence_count + 1 end
    if fence_count > 0 then code_score = code_score + 2 end
    -- Braces/brackets density (code tends to have more)
    local brace_count = 0
    for _ in text:gmatch("[{}()\\[\\]]") do brace_count = brace_count + 1 end
    if brace_count > len * 0.02 then code_score = code_score + 1 end
    -- XML/JSON indicators
    if text:match("<[a-zA-Z_][a-zA-Z0-9_-]*%s") or text:match("</[a-zA-Z_]") or
       text:match("<[a-zA-Z_][a-zA-Z0-9_-]*>") then
        xml_json_score = xml_json_score + 2
    end
    if text:match('^%s*[{\\[]') or text:match('"[^"]*"%s*:') then
        xml_json_score = xml_json_score + 2
    end
    -- Prose indicators (long sentences, punctuation)
    local sentence_count = 0
    for _ in text:gmatch("[.!?]%s") do sentence_count = sentence_count + 1 end
    if sentence_count > 3 then prose_score = prose_score + 2 end
    -- Average word length (prose tends to have shorter words)
    local word_count = 0
    local total_word_len = 0
    for word in text:gmatch("%S+") do
        word_count = word_count + 1
        total_word_len = total_word_len + #word
    end
    if word_count > 0 then
        local avg_word_len = total_word_len / word_count
        if avg_word_len < 5 then prose_score = prose_score + 1 end
    end
    -- Decision
    if code_score >= 4 then return "code" end
    if xml_json_score >= 3 then return "xml_json" end
    if code_score >= 2 then return "mixed" end
    if prose_score >= 2 then return "prose" end
    return "mixed" -- default fallback
end
-- Structural overhead calculation
local function _calculate_structural_overhead(text, content_type)
    local overhead = 0
    -- XML tags: each tag adds ~2-3 tokens
    local xml_tag_count = 0
    for _ in text:gmatch("</?[a-zA-Z_][a-zA-Z0-9_-]*[^>]*>") do
        xml_tag_count = xml_tag_count + 1
    end
    if xml_tag_count > 0 then
        overhead = overhead + math.ceil(xml_tag_count * 2.5)
    end
    -- JSON structural chars: { } [ ] : ,
    local json_struct_count = 0
    for _ in text:gmatch("[{}\\[\\]:,]") do
        json_struct_count = json_struct_count + 1
    end
    if json_struct_count > 10 then
        overhead = overhead + math.ceil(json_struct_count * 0.5)
    end
    -- Markdown fences
    local fence_count = 0
    for _ in text:gmatch("```") do fence_count = fence_count + 1 end
    if fence_count > 0 then
        overhead = overhead + math.ceil(fence_count * 1.5)
    end
    -- Long identifiers (>30 chars) tend to be tokenized inefficiently
    local long_id_count = 0
    for id in text:gmatch("%S+") do
        if #id > 30 and id:match("^[a-zA-Z0-9_./%-]+$") then
            long_id_count = long_id_count + 1
        end
    end
    if long_id_count > 0 then
        overhead = overhead + long_id_count
    end
    return overhead
end
function M:estimate_tokens(text, agent_cfg)
    if not text or #text == 0 then return 0 end
    -- Check cache first
    local cached = _cache_get(text)
    if cached then return cached end
    -- Determine base divisor from config hierarchy:
    -- 1. Per-agent override (agent_cfg.chars_per_token)
    -- 2. Flow config default
    -- 3. Hardcoded fallback
    local base_divisor = self.flow_config.token_estimation.chars_per_token or 3.5
    if agent_cfg and agent_cfg.chars_per_token then
        base_divisor = agent_cfg.chars_per_token
    end
    -- Detect content type
    local content_type = _detect_content_type(text)
    -- Content-type-specific divisors
    local divisors = {
        code     = 2.5,   -- Code is denser: fewer chars per token
        prose    = 3.5,   -- Natural language: standard ratio
        mixed    = 3.0,   -- Mix of code and prose
        xml_json = 3.2,   -- Structured data with tags/braces
        empty    = 3.5,
    }
    -- Use content-type divisor if it differs significantly from base
    local content_divisor = divisors[content_type] or base_divisor
    -- Blend: if agent has explicit override, weight it more heavily
    local effective_divisor
    if agent_cfg and agent_cfg.chars_per_token then
        -- 70% agent override, 30% content-type heuristic
        effective_divisor = agent_cfg.chars_per_token * 0.7 + content_divisor * 0.3
    else
        -- Use content-type divisor directly
        effective_divisor = content_divisor
    end
    -- Base token estimate
    local raw_tokens = math.ceil(#text / effective_divisor)
    -- Add structural overhead
    local overhead = _calculate_structural_overhead(text, content_type)
    local total = raw_tokens + overhead
    -- Cache the result
    _cache_set(text, total)
    return total
end

function M:purge_images()
    self.images = {}
    self.images_loaded = false
    self.last_sent_image_hashes = {}
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
        xml = xml .. "\n  <task_summary>" .. self.task_summary .. "\n  </task_summary>"
    end
    if self.execution_plan and #self.execution_plan > 0 then
        xml = xml .. "\n  <execution_plan>" .. self:get_plan_text() .. "\n  </execution_plan>"
    end
    if #self.last_actions > 0 then
        xml = xml .. "\n  <last_actions>" .. self:get_actions_text() .. "\n  </last_actions>"
    end
    return xml .. "\n</system_state>"
end

function M:get_recency_tool_outputs()
    if not self.recent_tool_outputs or #self.recent_tool_outputs == 0 then return "" end
    local parts = {"\n<recent_tool_outputs>"}
    for _, tool_out in ipairs(self.recent_tool_outputs) do
        table.insert(parts, string.format("\n  <tool_output name=\"%s\">\n%s\n  </tool_output>", tool_out.tool, (tool_out.output or "")))
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
            -- FIX: Match the exact <file_context path="..."> tag to avoid false positives
            -- from filenames appearing as substrings in unrelated text (e.g., "main" in "maintain")
            local is_in_history = false
            local escaped_path = path:gsub("[%(%)%.%%%+%-%*%?%[%^%$%|]", "%%%1")
            local tag_pattern = "<file_context%s+path=\"" .. escaped_path .. "\""
            for _, msg in ipairs(history) do
                if msg.content and string.find(msg.content, tag_pattern, 1, true) then
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
                    path, status, content
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
