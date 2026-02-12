local M = {}

function M.new(config)
    local self = setmetatable({}, { __index = M })
    self.config = config
    self.knowledge_base = {}     
    self.file_access_rank = {}
    self.global_access_counter = 0
    self.file_states = {} -- READ, PATCHED
    
    -- State
    self.chat_history = {}
    self.execution_plan = {}
    self.current_task_index = 1
    self.identity = nil
    return self
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

function M.get_report(self)
    return string.format(
        "# PROJECT CONTEXT\nRoot: %s\n---\n## FILE TREE\n```text\n%s\n```\n",
        self.config.PROJECT_ROOT, self.file_tree or "(empty)"
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

-- === КЛЮЧЕВОЕ ИЗМЕНЕНИЕ: ФОКУСИРОВКА НА ЦЕЛЕВОМ ФАЙЛЕ ===
function M.get_memory_block(self)
    -- Определяем текущий целевой файл из плана
    local current_task = self.execution_plan[self.current_task_index]
    local active_target = current_task and current_task.file

    local files_list = {}
    for path, content in pairs(self.knowledge_base) do
        table.insert(files_list, {
            path = path,
            content = content,
            rank = self.file_access_rank[path] or 0,
            is_target = (path == active_target)
        })
    end

    -- Сортировка: Сначала старые, в конце самые свежие (Target должен быть последним)
    table.sort(files_list, function(a, b) 
        if a.is_target and not b.is_target then return false end -- b < a
        if not a.is_target and b.is_target then return true end  -- a < b
        return a.rank < b.rank 
    end)

    local mem = "\n\n=== MEMORY ===\n"
    
    -- Оставляем только топ-5 файлов + Target
    local limit = 5
    local start_idx = math.max(1, #files_list - limit + 1)

    for i = start_idx, #files_list do
        local f = files_list[i]
        local status = self.file_states[f.path] or "READ"
        local marker = ""
        local display_content = f.content

        if f.is_target then
            marker = " [TARGET - FULL VIEW]"
            -- !!! ВАЖНО: Не обрезаем целевой файл, даже если он большой !!!
            -- Это предотвращает галлюцинации LLM о содержимом скрытых блоков
        else
            -- Фоновые файлы обрезаем, если они огромные
            if #display_content > 6000 then
                display_content = display_content:sub(1, 1000) .. 
                    "\n...[SNIPPED BACKGROUND FILE]...\n" .. 
                    display_content:sub(-1000)
            end
        end

        mem = mem .. string.format("FILE (%s)%s: %s\n```\n%s\n```\n", status, marker, f.path, display_content)
    end

    if #files_list == 0 then return mem .. "(Empty)\n" end
    return mem
end

function M.update_file_tree(self, tree_str)
    self.file_tree = tree_str
end

return M
