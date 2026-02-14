local M = {}
local json = require("JSON")

function M.new(config)
    local self = setmetatable({}, { __index = M })
    self.config = config
    self:reset()
    return self
end

-- Сброс состояния (Zeroing memory)
function M.reset(self)
    self.knowledge_base = {}
    self.file_access_rank = {}
    self.global_access_counter = 0
    self.file_states = {} 
    self.search_history = {}
    self.chat_history = {}
    self.execution_plan = {}
    self.current_task_index = 1
    self.identity = nil
    self.file_tree = nil
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

-- === SNAPSHOT SYSTEM (PERSISTENCE) ===
function M.snapshot(self)
    local state = {
        knowledge_base = self.knowledge_base,
        file_access_rank = self.file_access_rank,
        global_access_counter = self.global_access_counter,
        file_states = self.file_states,
        search_history = self.search_history,
        chat_history = self.chat_history,
        execution_plan = self.execution_plan,
        current_task_index = self.current_task_index,
        identity = self.identity,
        file_tree = self.file_tree
    }
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
    self.chat_history = state.chat_history or {}
    self.execution_plan = state.execution_plan or {}
    self.current_task_index = state.current_task_index or 1
    self.identity = state.identity
    self.file_tree = state.file_tree
    
    return true
end

-- === SMART MEMORY MANAGEMENT ===
function M.estimate_tokens(self, text)
    if not text then return 0 end
    local divisor = (self.config.LIMITS and self.config.LIMITS.CHARS_PER_TOKEN) or 3.5
    return math.ceil(#text / divisor)
end

function M.get_memory_block(self, max_tokens)
    max_tokens = max_tokens or 8000
    local current_tokens = 0
    local mem_buffer = {}
    
    -- 1. Определяем Target File
    local current_task = self.execution_plan[self.current_task_index]
    local active_target = current_task and current_task.file

    -- 2. Сортируем файлы: Target, потом Rank
    local files_list = {}
    for path, content in pairs(self.knowledge_base) do
        table.insert(files_list, {
            path = path,
            content = content,
            rank = self.file_access_rank[path] or 0,
            is_target = (path == active_target)
        })
    end

    table.sort(files_list, function(a, b)
        if a.is_target and not b.is_target then return true end
        if not a.is_target and b.is_target then return false end
        return a.rank > b.rank
    end)

    table.insert(mem_buffer, "\n=== MEMORY (Smart Context) ===\n")
    
    -- 3. Жадное заполнение
    for _, f in ipairs(files_list) do
        local file_header = string.format("FILE: %s\n```\n", f.path)
        local file_footer = "\n```\n"
        local content = f.content
        
        -- Сжатие неактивных больших файлов
        if not f.is_target and #content > 5000 then
             content = content:sub(1, 1000) .. "\n...[SNIPPED LARGE FILE]...\n" .. content:sub(-1000)
        end

        local total_str = file_header .. content .. file_footer
        local cost = self:estimate_tokens(total_str)

        if (current_tokens + cost) < max_tokens then
            table.insert(mem_buffer, total_str)
            current_tokens = current_tokens + cost
        else
            -- Target впихиваем любой ценой (если возможно)
            if f.is_target then
                 table.insert(mem_buffer, total_str)
                 current_tokens = current_tokens + cost
            else
                table.insert(mem_buffer, string.format("FILE: %s [HIDDEN to save tokens]\n", f.path))
            end
        end
    end

    if #files_list == 0 then return "\n=== MEMORY ===\n(Empty)\n" end
    return table.concat(mem_buffer, "")
end

function M.get_report(self)
    local search_summary = ""
    local count = 0
    for q, _ in pairs(self.search_history) do count = count + 1 end
    if count > 0 then
        search_summary = string.format("\n## SEARCH HISTORY\n(Cached %d queries)\n", count)
    end

    return string.format(
        "# PROJECT CONTEXT\nRoot: %s\n---\n## FILE TREE\n```text\n%s\n```\n%s",
        self.config.PROJECT_ROOT,
        self.file_tree or "(empty)",
        search_summary
    )
end

function M.get_identity_prompt(self)
    if not self.identity then return "" end
    return string.format(
        "\n=== IDENTITY ===\nROLE: %s\nSTACK: %s\nSUMMARY: %s\n",
        self.identity.persona or "Dev",
        table.concat(self.identity.stack or {}, ", "),
        self.identity.summary or "N/A"
    )
end

function M.update_file_tree(self, tree_str)
    self.file_tree = tree_str
end

return M
