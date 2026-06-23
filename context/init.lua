local M = {}
local json = require("JSON")
local utils = require("utils")
local logger = require("logger")

function M.new(config)
    local self = setmetatable({}, { __index = M })
    self.config = config
    self:reset()
    return self
end

function M.reset(self)
    self.recent_tool_outputs = {}
    self.max_recent_tools = 10  -- Добавлено: лимит для recent_tool_outputs
    self.knowledge_base = {}
    self.file_access_rank = {}
    self.global_access_counter = 0
    self.file_states = {}
    self.search_history = {}
    self.agent_histories = {}
    self.thoughts = {}
    self.execution_plan = {}
    self.current_task_index = 1
    self.identity = nil
    self.file_tree = nil
    self.pinned_files = {}
    self.images = {}
    self.images_loaded = false
    self.handoff_memo = nil
    self.test_failures = 0
    self.last_actions = {} -- Новые: последние N действий
    self.max_last_actions = 100
    self.task_summary = "" 
    self.turn_requested_files = {} -- Track files requested in the current turn for recency block
end

function M.track_requested_file(self, path)
    if not path then return end
    self.turn_requested_files[path] = true
end

function M.clear_turn_requested_files(self)
    self.turn_requested_files = {}
end

function M.update_summary(self, new_summary)
    self.task_summary = utils.trim(new_summary)
    -- Добавляем действие в историю для прозрачности
    self:add_action("SUMMARY_UPDATE", "Updated task summary")
end

function M.optimize_context(self, instructions)
    -- instructions может быть таблицей с командами, например:
    -- { remove_file = "path/to/file", pin_file = "path/to/core.h", update_summary = "New summary text" }
    -- Поддерживает батч-операции: remove_files, pin_files, unpin_files (массивы)
    if type(instructions) ~= "table" then return end

    if instructions.remove_file then
        self.knowledge_base[instructions.remove_file] = nil
        self.file_states[instructions.remove_file] = nil
        self.file_access_rank[instructions.remove_file] = nil
        self:add_action("CONTEXT_OPTIMIZATION", "Removed file from memory: " .. instructions.remove_file)
    end

    if instructions.pin_file then
        self:pin_file(instructions.pin_file)
    end

    if instructions.unpin_file then
        self:unpin_file(instructions.unpin_file)
    end

    if instructions.update_summary then
        self:update_summary(instructions.update_summary)
    end

    -- Batch operations (plural keys)
    if type(instructions.remove_files) == "table" then
        for _, path in ipairs(instructions.remove_files) do
            self.knowledge_base[path] = nil
            self.file_states[path] = nil
            self.file_access_rank[path] = nil
            self:add_action("CONTEXT_OPTIMIZATION", "Removed file from memory: " .. path)
        end
    end

    if type(instructions.pin_files) == "table" then
        for _, path in ipairs(instructions.pin_files) do
            self:pin_file(path)
        end
    end

    if type(instructions.unpin_files) == "table" then
        for _, path in ipairs(instructions.unpin_files) do
            self:unpin_file(path)
        end
    end
end
-- ============================================================================
-- НОВЫЙ: Распределенный контекст
-- ============================================================================

function M.get_system_prompt(self, agent_name, agent_cfg)
    local sys_prompt_text = self:load_prompt(self, agent_cfg.prompt_file)
    local toolchain_manifest = self:generate_tool_manifest(self, agent_cfg.allowed_tools)
    local engine_directives = self:get_engine_directives(self, agent_cfg)
    
    return sys_prompt_text .. "\n" ..
           toolchain_manifest .. "\n\n" ..
           engine_directives
end

function M.add_tool_output(self, tool_name, output)
    if not output or output == "" then return end
    -- Обрезаем гигантские выводы, чтобы не сожрать токен-бюджет динамического контекста
    local max_len = 1500
    local truncated_output = output
    if #output > max_len then
        truncated_output = output:sub(1, max_len) .. "\n...[TRUNCATED FOR RECENCY INJECTION]..."
    end
    
    table.insert(self.recent_tool_outputs, { 
        tool = tool_name, 
        output = truncated_output 
    })
    
    if #self.recent_tool_outputs > self.max_recent_tools then
        table.remove(self.recent_tool_outputs, 1)
    end
end

function M.calculate_max_commands(self, agent_name, available_tokens)
    local agent_cfg = self.config.AGENTS[agent_name]
    if not agent_cfg then return 5 end
    
    -- Базовый лимит зависит от типа агента
    local base_limit = 5
    if agent_cfg.name == "ARCHITECT" then
        base_limit = 8  
    elseif agent_cfg.name == "CODER" then
        base_limit = 3  -- Кодер должен быть более точным
    end
    
    -- Корректировка в зависимости от доступных токенов
    local token_ratio = available_tokens / (self.config.LIMITS.MAX_CONTEXT or 250000)
    if token_ratio < 0.2 then
        base_limit = math.max(1, math.floor(base_limit * 0.5))  -- Мало токенов — меньше команд
    elseif token_ratio > 0.8 then
        base_limit = math.min(15, base_limit * 2)  -- Много токенов — больше команд
    end
    
    return base_limit
end

function M.get_command_limit_info(self, agent_name, available_tokens)
    local max_cmds = self:calculate_max_commands(agent_name, available_tokens)
    return string.format(
        "COMMAND LIMIT: You can execute up to %d commands per turn. " ..
        "Use batch operations (e.g., read_files, search_and_read) to maximize efficiency. " ..
        "If you need to read multiple files, use <cmd>read_files:file1,file2,file3</cmd> instead of individual read_file commands.",
        max_cmds
    )
end

function M:build_system_state_xml()
    local xml = "<system_state>"

    if self.task_summary and self.task_summary ~= "" then
        local indented_summary = "\t" .. self.task_summary:gsub("\n", "\n\t")
        xml = xml .. "\n  <task_summary>" .. indented_summary .. "\n  </task_summary>"
    end

    if self.execution_plan and #self.execution_plan > 0 then
        local plan_text = self:get_execution_plan_text(self)
        local indented_plan = "\t" .. plan_text:gsub("\n", "\n\t")
        xml = xml .. "\n  <execution_plan>" .. indented_plan .. "\n  </execution_plan>"
    end

    if #self.last_actions > 0 then
        local actions_text = self:get_last_actions_text(self)
        local indented_actions = "\t" .. actions_text:gsub("\n", "\n\t")
        xml = xml .. "\n  <last_actions>" .. indented_actions .. "\n  </last_actions>"
    end

    return xml .. "\n</system_state>"
end

function M:format_file_content(path)
    local content = self.knowledge_base[path]
    if not content then return nil end

    local raw_lines = utils.read_lines_raw(content)
    local content_display = table.concat(raw_lines, "\n")
    return "\t" .. content_display:gsub("\n", "\n\t")
end

function M:compress_search_line(line)
    local pure_code = line:match("[:-]%d+[:-]%s*(.+)$") or line
    return pure_code:gsub("^%s+", ""):gsub("%s+", " ")
end

function M.get_recency_block(self)
    local parts = {}

    -- 1. Build <system_state> block using shared helper
    table.insert(parts, self:build_system_state_xml())

    -- 2. Iterate only turn-requested files and generate <file_context> blocks
    for path, _ in pairs(self.turn_requested_files) do
        local indented_content = self:format_file_content(path)
        if indented_content then
            local file_context = string.format(
                "\n<file_context path=\"%s\" status=\"READ_ONLY\">\n\n%s\n\n</file_context>",
                path, indented_content
            )
            table.insert(parts, file_context)
        end
    end

    -- 3. Return concatenated string
    return table.concat(parts, "\n")
end

function M.get_memory_block(self, max_tokens)
    max_tokens = max_tokens or 10000
    local current_tokens = 0
    local memory_parts = {}
    
    -- 1. Пин-файлы (только имена и статусы)
    if next(self.pinned_files) then
        local pinned_text = "\n=== PINNED FILES ===\n"
        for path, _ in pairs(self.pinned_files) do
            pinned_text = pinned_text .. string.format("- %s\n", path)
        end
        local cost = self:estimate_tokens(pinned_text)
        if current_tokens + cost < max_tokens then
            table.insert(memory_parts, pinned_text)
            current_tokens = current_tokens + cost
        end
    end
    
    -- 2. Сжатая история изменений
    local changes_text = self:get_changes_summary(self)
    local cost = self:estimate_tokens(changes_text)
    if current_tokens + cost < max_tokens then
        table.insert(memory_parts, changes_text)
        current_tokens = current_tokens + cost
    end
    
    -- 3. Ключевые выводы
    local insights_text = self:get_insights_summary(self)
    cost = self:estimate_tokens(insights_text)
    if current_tokens + cost < max_tokens then
        table.insert(memory_parts, insights_text)
        current_tokens = current_tokens + cost
    end
    
    return table.concat(memory_parts, "\n")
end

-- ============================================================================
-- Вспомогательные функции для распределенного контекста
-- ============================================================================

function M:get_execution_plan_text(self)
    if not self.execution_plan or #self.execution_plan == 0 then
        return ""
    end
    
    local text = "\n=== EXECUTION PLAN ===\n"
    for i, task in ipairs(self.execution_plan) do
        local status_marker = (i < self.current_task_index) and "[x]" or
                             (i == self.current_task_index) and "[>]" or "[ ]"
        text = text .. string.format(
            "%s Step %d: %s -> %s\n",
            status_marker, i, tostring(task.file), tostring(task.instruction)
        )
    end
    return text
end

function M:get_last_actions_text(self)
    if #self.last_actions == 0 then return "" end
    
    local text = "\n=== LAST ACTIONS ===\n"
    for _, action in ipairs(self.last_actions) do
        text = text .. string.format("- %s: %s\n", action.type, action.summary)
    end
    return text
end

function M:get_recent_thoughts_text(self)
    if not self.thoughts or #self.thoughts == 0 then return "" end
    
    local text = "\n=== RECENT THOUGHTS ===\n"
    local start_idx = math.max(1, #self.thoughts - 140) -- Только последние 140 мысли
    for i = start_idx, #self.thoughts do
        local th = self.thoughts[i]
        text = text .. string.format("-----\n%s\n", th.content)
    end
    return text
end

function M:get_changes_summary(self)
    local text = "\n=== CHANGES SUMMARY ===\n"
    for path, state in pairs(self.file_states) do
        if state == "RECENTLY_MODIFIED" then
            text = text .. string.format("- %s: modified\n", path)
        end
    end
    return text
end

function M:get_insights_summary(self)
    if not next(self.search_history) then return "" end
    
    local text = "\n=== SEARCH INSIGHTS ===\n"
    for query, result in pairs(self.search_history) do
        local lines = {}
        for line in result:gmatch("[^\r\n]+") do
            local pure_code = line:match("[:-]%d+[:-]%s*(.+)$") or line
            local compressed_line = pure_code:gsub("^%s+", ""):gsub("%s+", " ")
            if compressed_line ~= "" then
                table.insert(lines, compressed_line)
            end
        end
        text = text .. string.format("- %s: %s\n", query, table.concat(lines, "; "))
    end
    return text
end

function M:get_engine_directives(self, agent_cfg)
    local has_delegate = false
    local has_complete = false
    for _, t in ipairs(agent_cfg.allowed_tools or {}) do
        if t == "delegate_plan" or t == "*" then has_delegate = true end
        if t == "task_complete" or t == "*" then has_complete = true end
    end
    
    local pipeline_rule = "1. PIPELINE CONTROL: "
    if has_delegate and has_complete then
        pipeline_rule = pipeline_rule .. "To advance the pipeline, use `<cmd>delegate_plan</cmd>` to assign work to the next stage, OR use `<cmd>task_complete</cmd>` if no code changes are needed."
    elseif has_delegate then
        pipeline_rule = pipeline_rule .. "To advance the pipeline, you MUST use `<cmd>delegate_plan</cmd>` to assign work."
    elseif has_complete then
        pipeline_rule = pipeline_rule .. "To advance or finish your stage, you MUST execute `<cmd>task_complete</cmd>`."
    else
        pipeline_rule = pipeline_rule .. "Analyze the context and answer the user."
    end
    
    return string.format([[
==================================================
⚙️ ENGINE DIRECTIVES (CRITICAL & NON-NEGOTIABLE):
%s
2. STRICT TOOL SYNTAX: You MUST wrap all tool executions STRICTLY in `<cmd>tool:args</cmd>` tags.
Example: <cmd>read_file:src/main.c</cmd>
3. EXECUTION ORDER: The system parses and executes commands from the END of your response. Place critical commands at the end.
==================================================]], pipeline_rule)
end

function M:load_prompt(self, file_path)
    if not file_path then return "You are an AI assistant. Follow the user's instructions." end
    local local_path = self.config.PROJECT_ROOT .. "/.e-va-conf/" .. file_path
    local content = utils.read_file_range(local_path)
    if not content then
        local proj_path = self.config.PROJECT_ROOT .. "/" .. file_path
        content = utils.read_file_range(proj_path)
    end
    if not content then
        local global_path = os.getenv("AGENT_HOME") .. "/" .. file_path
        content = utils.read_file_range(global_path)
    end
    if not content then
        return "You are an AI assistant. Follow the user's instructions."
    end
    return content
end

function M:generate_tool_manifest(self, allowed_tools)
    local registry = require("tool_registry")
    return registry.generate_tool_manifest(allowed_tools)
end

-- ============================================================================
-- Обновленные методы для работы с распределенным контекстом
-- ============================================================================

function M.add_action(self, action_type, summary)
    table.insert(self.last_actions, {
        type = action_type,
        summary = summary
    })
    if #self.last_actions > self.max_last_actions then
        table.remove(self.last_actions, 1)
    end
end

function M.get_history(self, agent_name)
    self.agent_histories[agent_name] = self.agent_histories[agent_name] or {}
    return self.agent_histories[agent_name]
end

function M.add_message(self, agent_name, role, content)
    local history = self:get_history(agent_name)
    if #history > 0 and history[#history].role == role then
        logger.warn("Replacing consecutive " .. role .. " message")
        history[#history] = { role = role, content = content }
    else
        table.insert(history, { role = role, content = content })
    end
end

function M.drop_last_message(self, agent_name)
    local history = self:get_history(agent_name)
    if #history > 0 then
        table.remove(history)
        return true
    end
    return false
end

function M.replace_last_assistant_message(self, agent_name, new_content)
    local history = self:get_history(agent_name)
    for i = #history, 1, -1 do
        if history[i].role == "assistant" then
            history[i].content = new_content
            return true
        end
    end
    return false
end

function M.add_thought(self, turn, thought_text)
    self.thoughts = self.thoughts or {}
    local clean_thought = utils.trim(thought_text)
    if clean_thought == "" then return end
    table.insert(self.thoughts, { turn = turn, content = clean_thought })
end

function M.get_thoughts_digest(self)
    if not self.thoughts or #self.thoughts == 0 then return "" end
    local out = {"\n!=== AGENT RECENT THOUGHTS ===!"}
    for _, th in ipairs(self.thoughts) do
        table.insert(out, th.content)
    end
    return table.concat(out, "\n")
end

function M.touch_file(self, path)
    if not path or not self.knowledge_base[path] then return end
    self.global_access_counter = self.global_access_counter + 1
    self.file_access_rank[path] = self.global_access_counter
end

function M.add_file(self, path, content)
    self.knowledge_base[path] = content
    self.file_states[path] = "READ"
    self:touch_file(path)
end

function M.has_searched(self, query)
    return self.search_history[query] ~= nil
end

function M.add_search_result(self, query, result)
    self.search_history[query] = result
end

function M.pin_file(self, path)
    if self.knowledge_base[path] then
        self.pinned_files[path] = true
        return true
    end
    return false
end

function M.unpin_file(self, path)
    if self.pinned_files[path] then
        self.pinned_files[path] = nil
        return true
    end
    return false
end

function M.load_images(self, dir_path)
    if not dir_path or dir_path == "" then
        self.images = {}
        self.images_loaded = false
        return
    end
    self.images = utils.load_images_from_dir(dir_path)
    self.images_loaded = (#self.images > 0)
end

function M.get_image_content_parts(self)
    if not self.images or #self.images == 0 then return {} end
    local parts = {}
    for _, img in ipairs(self.images) do
        table.insert(parts, {
            type = "image_url",
            image_url = {
                url = "data:" .. img.mime_type .. ";base64," .. img.base64_data
            }
        })
    end
    return parts
end

function M.snapshot(self)
    local state = {
        knowledge_base = self.knowledge_base,
        file_access_rank = self.file_access_rank,
        global_access_counter = self.global_access_counter,
        file_states = self.file_states,
        search_history = self.search_history,
        agent_histories = self.agent_histories,
        thoughts = self.thoughts,
        execution_plan = self.execution_plan,
        current_task_index = self.current_task_index,
        identity = self.identity,
        file_tree = self.file_tree,
        pinned_files = self.pinned_files,
        images_loaded = self.images_loaded,
        images_metadata = nil,
        last_actions = self.last_actions,
        handoff_memo = self.handoff_memo,
        test_failures = self.test_failures,
        turn_requested_files = self.turn_requested_files
    }
    if self.images and #self.images > 0 then
        state.images_metadata = {}
        for _, img in ipairs(self.images) do
            table.insert(state.images_metadata, {
                path = img.path,
                mime_type = img.mime_type
            })
        end
    end
    return json:encode(state)
end

function M.load_from_snapshot(self, json_str)
    local status, state = pcall(function() return json:decode(json_str) end)
    if not status or not state then return false, "Corrupted JSON" end
    self.knowledge_base = state.knowledge_base or {}
    self.file_access_rank = state.file_access_rank or {}
    self.global_access_counter = state.global_access_counter or 0
    self.file_states = state.file_states or {}
    self.search_history = state.search_history or {}
    self.agent_histories = state.agent_histories or {}
    self.thoughts = state.thoughts or {}
    self.execution_plan = state.execution_plan or {}
    self.current_task_index = state.current_task_index or 1
    self.identity = state.identity
    self.file_tree = state.file_tree
    self.pinned_files = state.pinned_files or {}
    self.images_loaded = state.images_loaded or false
    self.images = {}
    if state.images_metadata and type(state.images_metadata) == "table" then
        for _, meta in ipairs(state.images_metadata) do
            table.insert(self.images, {
                path = meta.path,
                mime_type = meta.mime_type,
                base64_data = nil
            })
        end
    end
    self.last_actions = state.last_actions or {}
    self.handoff_memo = state.handoff_memo
    self.test_failures = state.test_failures or 0
    return true
end

function M.estimate_tokens(self, text)
    if not text then return 0 end
    local divisor = (self.config.LIMITS and self.config.LIMITS.CHARS_PER_TOKEN) or 3.5
    return math.ceil(#text / divisor)
end

function M.get_search_digest(self, max_tokens)
    if not next(self.search_history) then return "" end
    local digest_buffer = {"\n=== SEARCH DIGEST (Reference Snippets) ==="}
    local seen_hashes = {}
    local current_tokens = 0
    local divisor = (self.config.LIMITS and self.config.LIMITS.CHARS_PER_TOKEN) or 3.5
    for query, res in pairs(self.search_history) do
        table.insert(digest_buffer, "--- Query: " .. query .. " ---")
        for line in res:gmatch("[^\r\n]+") do
            local pure_code = line:match("[:-]%d+[:-]%s*(.+)$") or line
            local compressed_line = pure_code:gsub("^%s+", ""):gsub("%s+", " ")
            local hash = compressed_line:gsub("%s", "")
            if hash ~= "" and not seen_hashes[hash] then
                seen_hashes[hash] = true
                table.insert(digest_buffer, compressed_line)
                current_tokens = current_tokens + math.ceil(#compressed_line / divisor)
                if current_tokens >= max_tokens then
                    table.insert(digest_buffer, "... [TRUNCATED DUE TO TOKEN LIMIT] ...")
                    return table.concat(digest_buffer, "\n")
                end
            end
        end
    end
    return table.concat(digest_buffer, "\n")
end

function M.get_report(self, agent_name)
    local search_summary = ""
    local count = 0
    for _,_ in pairs(self.search_history) do count = count + 1 end
    if count > 0 then
        search_summary = string.format("\n## SEARCH HISTORY\n(Cached %d queries)\n", count)
    end
    local tree_content = self.file_tree or "(empty)"
    if #tree_content > 30000 then
        tree_content = tree_content:sub(1, 30000) .. "\n... [TREE TRUNCATED - USE <cmd>explore_tree:path:depth</cmd> TO NAVIGATE]"
    end
    local tree_block = string.format("## PROJECT STRUCTURE (Current View)\n```text\n%s\n```\n", tree_content)
    return string.format(
        "# PROJECT CONTEXT\nRoot: %s\n---\n%s%s",
        self.config.PROJECT_ROOT,
        tree_block,
        search_summary
    )
end

function M.sync_files(self)
    local updated_files = {}
    for path, old_content in pairs(self.knowledge_base) do
        local full_path = self.config.PROJECT_ROOT .. "/" .. path
        local new_content = utils.read_file_range(full_path)
        if new_content and new_content ~= old_content then
            self.knowledge_base[path] = new_content
            table.insert(updated_files, path)
        end
    end
    return updated_files
end

function M.squash_last_mutation(self, agent_name)
    local history = self:get_history(agent_name)
    for i = #history, 1, -1 do
        local msg = history[i]
        if msg.role == "assistant" then
            local original = msg.content or ""
            local squashed = original
            squashed = squashed:gsub(
                "<cmd>patch:([^%s\n]+)%s*\n<<<<<<< SEARCH.->>>>>>> REPLACE\n</cmd>",
                function(file_path)
                    return string.format("\n[SYSTEM MEMORY: Patch applied to '%s'. Code updated.]\n", file_path or "unknown file")
                end
            )
            squashed = squashed:gsub(
                "<cmd>create_file:([^%s\n]+)%s*\n.-</cmd>",
                function(file_path)
                    return string.format("\n[SYSTEM MEMORY: File '%s' created/overwritten.]\n", file_path or "unknown file")
                end
            )
            squashed = squashed:gsub("\n\n+", "\n\n")
            squashed = utils.trim(squashed)
            if original ~= squashed then
                history[i].content = squashed
                return true
            end
            break
        end
    end
    return false
end

return M