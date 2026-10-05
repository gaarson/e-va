local M = {}
local utils = require("utils")
local registry = require("tool_registry")

M.STATES = {
    IDLE = "IDLE",
    EXECUTING = "EXECUTING",
    WAITING_USER = "WAITING_USER",
    COMPLETED = "COMPLETED",
    ERROR = "ERROR"
}

function M.new(ctx, agent_name)
    return setmetatable({
        ctx = ctx,
        agent_name = agent_name,
        state = M.STATES.IDLE,
        retry_count = 0,
        max_retries = 3,
        cmd_start = "||| COMMAND |||",
        cmd_end = "||| END_COMMAND |||"
    }, { __index = M })
end

-- Вспомогательная функция для экранирования спецсимволов Lua (magic characters)
local function escape_pattern(str)
    -- Добавлен |, так как в паттернах Lua это оператор альтернативы (OR), а не разделитель
    return str:gsub("[%(%)%.%%%+%-%*%?%[%^%$%|]", "%%%1")
end

-- Парсинг: строгий поиск маркеров на отдельных строках
-- Парсинг: строгий поиск маркеров на отдельных строках
-- FIX: Only strip markdown fences that wrap the ENTIRE command block,
-- never strip backticks that appear inside the payload.
function M:parse_command(text)
    if not text or type(text) ~= "string" then return nil, "Empty response" end

    -- Normalize line endings only
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\\u000a", "\n")
    local lines = {}
    for line in text:gmatch("([^\n]*)") do
        table.insert(lines, line)
    end

    local start_pat = "^%s*|+%s*COMMAND%s*|+%s*$"
    local end_pat   = "^%s*|+%s*END_COMMAND%s*|+%s*$"

    local start_idx = nil
    local end_idx = nil

    -- Find first valid opening marker
    for i = 1, #lines do
        if lines[i]:match(start_pat) then
            start_idx = i
            break
        end
    end

    if not start_idx then
        return nil, "No valid command block found. Markers must be on their own lines without extra text."
    end

    -- Find first valid closing marker AFTER the opening one
    for i = start_idx + 1, #lines do
        if lines[i]:match(end_pat) then
            end_idx = i
            break
        end
    end

    if not end_idx then
        return nil, "Missing closing command marker. Ensure end marker is on its own line."
    end

    -- Collect body lines strictly between markers
    local cmd_lines = {}
    for i = start_idx + 1, end_idx - 1 do
        table.insert(cmd_lines, lines[i])
    end

    -- STRIP OUTER MARKDOWN FENCES ONLY:
    -- Check if the body is wrapped in matching ``` ... ``` fences.
    -- CRITICAL: Never strip backticks that appear inside the payload.
    -- Only strip if the ENTIRE body is wrapped in a single pair of fences.
    local function strip_outer_fences(lns)
        -- (1) Find first non-empty line
        local first = 1
        while first <= #lns and lns[first]:match("^%s*$") do first = first + 1 end
        -- (2) Find last non-empty line
        local last = #lns
        while last >= 1 and lns[last]:match("^%s*$") do last = last - 1 end
        if first > last then return lns end -- all empty
        local first_line = lns[first]
        local last_line  = lns[last]
        -- (3) Check if first line opens a fence and last line closes it
        local open_fence = first_line:match("^%s*(`+)%s*$") or first_line:match("^%s*(`+)%s*%w*$")
        local close_fence = last_line:match("^%s*(`+)%s*$")
        if open_fence and close_fence then
            -- (4) Verify backtick counts match
            if #open_fence == #close_fence then
                -- (5) SAFEGUARD: Check if ANY line between first and last contains ||| COMMAND |||
                local has_nested_command = false
                for i = first + 1, last - 1 do
                    if lns[i]:match("|+%s*COMMAND%s*|+") then
                        has_nested_command = true
                        break
                    end
                end
                -- (6) SAFEGUARD: Check if there are OTHER backtick fences inside the body
                -- If there are internal fences, do NOT strip the outer ones
                local has_internal_fences = false
                for i = first + 1, last - 1 do
                    if lns[i]:match("^%s*`+`*%s*$") or lns[i]:match("^%s*`+`*%s*%w*$") then
                        has_internal_fences = true
                        break
                    end
                end
                if not has_nested_command and not has_internal_fences then
                    -- (7) Remove the first and last fence lines
                    local stripped = {}
                    for i = 1, first - 1 do stripped[#stripped + 1] = lns[i] end
                    for i = first + 1, last - 1 do stripped[#stripped + 1] = lns[i] end
                    for i = last + 1, #lns do stripped[#stripped + 1] = lns[i] end
                    return stripped
                end
            end
        end
        return lns
    end

    cmd_lines = strip_outer_fences(cmd_lines)

    local cmd_body = table.concat(cmd_lines, "\n")
    cmd_body = utils.trim(cmd_body)
    cmd_body = cmd_body:gsub("\n\n+", "\n")
    if cmd_body == "" then
        return nil, "Command body is empty."
    end

    return cmd_body, nil
end

-- Input sanitization: check for dangerous patterns in shell commands
local function _sanitize_shell_command(args)
    if not args then return true, nil end
    local logger = require("logger")
    local dangerous_patterns = {
        { pattern = "sudo%s+", desc = "uses sudo", severity = "BLOCK" },
        { pattern = "rm%s+-rf%s+/?$", desc = "rm -rf on root", severity = "BLOCK" },
        { pattern = ">+/etc/", desc = "redirects to /etc/", severity = "BLOCK" },
        { pattern = ">+/usr/bin/", desc = "redirects to /usr/bin/", severity = "BLOCK" },
        { pattern = ">+/usr/sbin/", desc = "redirects to /usr/sbin/", severity = "BLOCK" },
        { pattern = "%-%-.*(/etc/)", desc = "writes to /etc/", severity = "WARN" },
        { pattern = "chmod%s+[0-7]*777", desc = "world-writable chmod", severity = "WARN" },
        { pattern = "curl[^|]*%|%s*(/bin/)?(ba)?sh", desc = "pipe curl to shell", severity = "BLOCK" },
        { pattern = "wget[^|]*%|%s*(/bin/)?(ba)?sh", desc = "pipe wget to shell", severity = "BLOCK" },
    }
    for _, rule in ipairs(dangerous_patterns) do
        if args:match(rule.pattern) then
            if rule.severity == "BLOCK" then
                logger.error(string.format("[SANITIZE BLOCKED] Dangerous shell command: %s", rule.desc))
                return false, string.format("Command blocked for safety: %s", rule.desc)
            else
                logger.warn(string.format("[SANITIZE] Suspicious shell command detected: %s", rule.desc))
            end
        end
    end
    return true, nil
end
-- Input sanitization: validate patch command has proper SEARCH/REPLACE blocks
local function _validate_patch_format(args)
    if not args then return false, "Patch command has no arguments" end
    -- Must contain at least one SEARCH/REPLACE pair
    if not args:match("<<<<<<< SEARCH") then
        return false, "Patch command missing '<<<<<<< SEARCH' marker"
    end
    if not args:match(">>>>>>> REPLACE") then
        return false, "Patch command missing '>>>>>>> REPLACE' marker"
    end
    -- Count markers — must have equal numbers
    local search_count = 0
    for _ in args:gmatch("<<<<<<< SEARCH") do search_count = search_count + 1 end
    local replace_count = 0
    for _ in args:gmatch(">>>>>>> REPLACE") do replace_count = replace_count + 1 end
    if search_count ~= replace_count then
        return false, string.format("Mismatched SEARCH/REPLACE blocks: %d SEARCH vs %d REPLACE", search_count, replace_count)
    end
    -- Must have ======= separator(s)
    local eq_count = 0
    for _ in args:gmatch("=======\n?") do eq_count = eq_count + 1 end
    if eq_count < search_count then
        return false, "Patch command missing '=======' separator(s)"
    end
    return true, nil
end
-- Валидация: существует ли такой тул и разрешен ли он?
function M:validate_command(cmd)
    -- Парсим до первого двоеточия. Если его нет, берем всю строку (например, команда "ask_user" без аргументов)
    local tool_name = cmd:match("^([^:]+)") or cmd
    tool_name = utils.trim(tool_name)
    if tool_name == "" then
        return false, "Invalid command format. Expected: tool_name:arguments"
    end
    local agent_cfg = self.ctx.config.AGENTS[self.agent_name]
    if not registry.is_tool_allowed(agent_cfg, tool_name) then
        return false, string.format("Unauthorized tool '%s'.", tool_name)
    end
    if not registry.tools[tool_name] then
        return false, string.format("Unknown tool '%s'.", tool_name)
    end
    -- Sanitize shell commands
    if tool_name == "shell" then
        local args = cmd:match("^shell:%s*(.*)")
        if args then
            local ok, err = _sanitize_shell_command(args)
            if not ok then
                return false, err
            end
        end
    end
    -- Validate patch format
    if tool_name == "patch" then
        local args = cmd:match("^patch:%s*(.*)")
        if args then
            -- Extract the diff portion (after the file path line)
            local rest = args:match("^[^\r\n]+\r?\n(.*)") or args
            local ok, err = _validate_patch_format(rest)
            if not ok then
                return false, err
            end
        end
    end
    return true, nil
end

-- Основной метод обработки хода
function M:process_turn(response_text)
    if self.state == M.STATES.COMPLETED then
        return { type = "COMPLETED", message = "Task already marked as complete." }
    end

    local cmd, parse_err = self:parse_command(response_text)

    -- 1. Если команды нет -> это просто разговор/анализ
    if not cmd then
        self.state = M.STATES.IDLE
        self.retry_count = 0
        return { type = "CONVERSATION", content = response_text, hint = parse_err }
    end

    -- 2. Валидация команды
    local valid, val_err = self:validate_command(cmd)
    if not valid then
        self.retry_count = self.retry_count + 1
        if self.retry_count >= self.max_retries then
            self.state = M.STATES.ERROR
            return { type = "ERROR", message = "Command validation failed after " .. self.max_retries .. " attempts." }
        end
        return { type = "RETRY", message = string.format("Command rejected: %s. Please output exactly one valid command.", val_err) }
    end

    self.state = M.STATES.EXECUTING
    self.retry_count = 0

    local tool_name = cmd:match("^([^:]+)") or cmd
    tool_name = utils.trim(tool_name)

    -- 3. Специальная обработка ask_user
    if tool_name == "ask_user" then
        self.state = M.STATES.WAITING_USER
        -- Извлекаем вопрос, если он есть после двоеточия
        local question = cmd:match("^ask_user:(.*)") or "No question provided"
        return { type = "USER_QUESTION", question = utils.trim(question) }
    end

    -- 4. Выполнение команды
    local res = registry.execute(cmd, self.ctx, self.agent_name)

    if res.signal == "PIPELINE_NEXT_STAGE" then
        self.state = M.STATES.COMPLETED
        return { type = "COMPLETED", output = res.output }
    end

    self.state = M.STATES.IDLE
    return { type = "EXECUTED", tool = tool_name, output = res.output, signal = res.signal }
end

function M:reset()
    self.state = M.STATES.IDLE
    self.retry_count = 0
end

return M
