local M = {}
local json = require("JSON")

function M.new(config)
    local self = setmetatable({}, { __index = M })
    self.config = config
    self:reset()
    return self
end

function M.reset(self)
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
end

function M.get_history(self, agent_name)
    self.agent_histories[agent_name] = self.agent_histories[agent_name] or {}
    return self.agent_histories[agent_name]
end

function M.add_message(self, agent_name, role, content)
    local history = self:get_history(agent_name)
    table.insert(history, { role = role, content = content })
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

local function calculate_similarity(s1, s2)
    local w1, w2 = {}, {}
    local set_size1, set_size2 = 0, 0
    
    for w in s1:gmatch("%a+") do 
        local lw = w:lower()
        if not w1[lw] then w1[lw] = true; set_size1 = set_size1 + 1 end
    end
    for w in s2:gmatch("%a+") do 
        local lw = w:lower()
        if not w2[lw] then w2[lw] = true; set_size2 = set_size2 + 1 end
    end
    
    if set_size1 == 0 or set_size2 == 0 then return 0 end
    
    local intersect = 0
    for w in pairs(w1) do if w2[w] then intersect = intersect + 1 end end
    
    local union = set_size1 + set_size2 - intersect
    return intersect / union
end

local function prioritize_memory_blocks(a, b)
    if a.is_target ~= b.is_target then
        return a.is_target
    end
    if a.is_pinned ~= b.is_pinned then
        return a.is_pinned
    end
    if a.rank ~= b.rank then
        return a.rank > b.rank
    end
    return a.path < b.path
end

function M.add_thought(self, turn, thought_text)
    self.thoughts = self.thoughts or {}
    local clean_thought = require("utils").trim(thought_text)
    if clean_thought == "" then return end

    local MERGE_THRESHOLD = 0.65

    if #self.thoughts > 0 then
        local last_thought = self.thoughts[#self.thoughts]
        local current_merge_count = last_thought.merged or 1
        
        if clean_thought:find(last_thought.content, 1, true) then
            last_thought.turn = turn
            last_thought.content = clean_thought
            last_thought.merged = current_merge_count + 1
            return
        end

        local sim = calculate_similarity(last_thought.content, clean_thought)
        if sim > MERGE_THRESHOLD then
            last_thought.turn = turn
            last_thought.content = clean_thought
            last_thought.merged = current_merge_count + 1
            return
        end
    end

    table.insert(self.thoughts, { turn = turn, content = clean_thought, merged = 1 })
    if #self.thoughts > 5 then table.remove(self.thoughts, 1) end
end

function M.get_thoughts_digest(self)
    if not self.thoughts or #self.thoughts == 0 then return "" end
    local out = {"\n=== AGENT RECENT THOUGHTS (Continuity) ==="}
    for _, th in ipairs(self.thoughts) do
        local header = string.format("--- Turn %d Thought ---", th.turn)
        if th.merged and th.merged > 1 then
            header = string.format("--- Turn %d Thought (Merged x%d) ---", th.turn, th.merged)
        end
        table.insert(out, header .. "\n" .. th.content)
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
        pinned_files = self.pinned_files
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
    self.agent_histories = state.agent_histories or {}
    self.thoughts = state.thoughts or {}
    self.execution_plan = state.execution_plan or {}
    self.current_task_index = state.current_task_index or 1
    self.identity = state.identity
    self.file_tree = state.file_tree
    self.pinned_files = state.pinned_files or {}
    return true
end

function M.estimate_tokens(self, text)
    if not text then return 0 end
    local divisor = (self.config.LIMITS and self.config.LIMITS.CHARS_PER_TOKEN) or 3.5
    return math.ceil(#text / divisor)
end

function M.get_memory_block(self, max_tokens)
    max_tokens = max_tokens or 100000
    local current_tokens = 0

    local pinned_buffer = {}
    local ctx_buffer = {}
    local target_buffer = ""

    local current_task = self.execution_plan[self.current_task_index]
    local active_target = current_task and current_task.file
    local target_instruction = current_task and current_task.instruction or "N/A"

    local files_list = {}
    for path, content in pairs(self.knowledge_base) do
        table.insert(files_list, {
            path = path,
            content = content,
            rank = self.file_access_rank[path] or 0,
            is_target = (path == active_target),
            is_pinned = self.pinned_files[path] == true
        })
    end

    table.sort(files_list, prioritize_memory_blocks)

    for _, f in ipairs(files_list) do
        local raw_lines = require("utils").read_lines_raw(f.content)
        local content_display = table.concat(raw_lines, "\n")

        local total_str = ""
        local cost = 0

        if f.is_target then
            total_str = string.format("\n<file_target path=\"%s\" instruction=\"%s\">\n%s\n</file_target>\n", f.path, target_instruction, content_display)
        elseif f.is_pinned then
            total_str = string.format("\n<file_context path=\"%s\" status=\"PINNED\">\n%s\n</file_context>\n", f.path, content_display)
        else
            total_str = string.format("\n<file_context path=\"%s\" status=\"READ_ONLY\">\n%s\n</file_context>\n", f.path, content_display)
        end

        cost = self:estimate_tokens(total_str)

        if (current_tokens + cost) < max_tokens then
            current_tokens = current_tokens + cost
            if f.is_target then
                target_buffer = total_str
            elseif f.is_pinned then
                table.insert(pinned_buffer, total_str)
            else
                table.insert(ctx_buffer, total_str)
            end
        else
            if f.is_target then
                target_buffer = total_str
                current_tokens = current_tokens + cost
            else
                table.insert(ctx_buffer, string.format("\n<file_context path=\"%s\" status=\"OMITTED_OUT_OF_MEMORY\" />\n", f.path))
            end
        end
    end

    local final_output = {"\n=== MEMORY (XML FRAMED CONTEXT) ===\n"}

    if self.execution_plan and #self.execution_plan > 0 then
        table.insert(final_output, "=== EXECUTION PLAN STATUS ===\n")
        for i, task in ipairs(self.execution_plan) do
            local status_marker
            if i < self.current_task_index then
                status_marker = "[x]"
            elseif i == self.current_task_index then
                status_marker = "[>]"
            else
                status_marker = "[ ]"
            end
            table.insert(final_output, string.format("%s Step %d: %s -> %s\n", status_marker, i, tostring(task.file), tostring(task.instruction)))
        end
        table.insert(final_output, "\n")
    end

    if #pinned_buffer > 0 then
        table.insert(final_output, "\n")
        table.insert(final_output, table.concat(pinned_buffer, ""))
    end
    if #ctx_buffer > 0 then
        table.insert(final_output, "\n")
        table.insert(final_output, table.concat(ctx_buffer, ""))
    end
    if target_buffer ~= "" then
        table.insert(final_output, "\n")
        table.insert(final_output, target_buffer)
    end

    if #files_list == 0 then 
        table.insert(final_output, "\n(No files loaded in memory)\n") 
    end
    
    return table.concat(final_output, "")
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

function M.squash_last_mutation(self, agent_name)
    local history = self:get_history(agent_name)
    for i = #history, 1, -1 do
        local msg = history[i]
        if msg.role == "assistant" then
            local original = msg.content or ""
            local squashed = original

            squashed = squashed:gsub(
                "<cmd>patch:([^%s\n]+)\n<<<<<<< SEARCH.->>>>>>> REPLACE\n</cmd>",
                "\n[SYSTEM NOTE: Patch successfully applied to '%1'. Changes are in memory.]\n"
            )

            squashed = squashed:gsub(
                "<cmd>create_file:([^%s\n]+)\n.-</cmd>",
                "\n[SYSTEM NOTE: File '%1' successfully created.]\n"
            )

            if original ~= squashed then
                history[i].content = squashed
                return true
            end
            break
        end
    end
    return false
end

function M.get_report(self, agent_name)
    local search_summary = ""
    local count = 0
    for _, _ in pairs(self.search_history) do count = count + 1 end
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
    local utils = require("utils")
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

return M