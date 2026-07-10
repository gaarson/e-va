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
    return str:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")
end

-- Парсинг: ищем ровно один блок между маркерами, игнорируя markdown и мусор
function M:parse_command(text)
    if not text or type(text) ~= "string" then return nil, "Empty response" end

    -- 1. Очистка от Markdown-оберток (например, ```json ... ``` или просто ```)
    -- Сначала убираем открывающие теги с названием языка (например ```bash\n)
    text = text:gsub("```%w*\n", "")
    -- Затем убираем оставшиеся обратные кавычки
    text = text:gsub("```", "")

    local start_pat = escape_pattern(self.cmd_start)
    local end_pat = escape_pattern(self.cmd_end)

    local commands = {}
    local current_pos = 1

    -- 2. Ищем блоки через точные индексы (надежнее, чем gmatch или match с .-)
    while true do
        local s_start, s_end = text:find(start_pat, current_pos)
        if not s_start then break end

        local e_start, e_end = text:find(end_pat, s_end + 1)
        local cmd_body

        if e_start then
            -- Идеальный сценарий: найден закрывающий маркер
            cmd_body = text:sub(s_end + 1, e_start - 1)
            current_pos = e_end + 1
        else
            -- Fallback: закрывающего маркера нет.
            -- Берем текст до двойного переноса строки (пустой строки), 
            -- чтобы отсечь последующие рассуждения агента, если он забыл закрыть блок.
            local remainder = text:sub(s_end + 1)
            local empty_line_pos = remainder:find("\n%s*\n")
            
            if empty_line_pos then
                cmd_body = remainder:sub(1, empty_line_pos - 1)
            else
                cmd_body = remainder
            end
            current_pos = #text + 1 -- Завершаем поиск, так как дошли до конца
        end

        cmd_body = utils.trim(cmd_body)
        if cmd_body ~= "" then
            table.insert(commands, cmd_body)
        end
    end

    -- 3. Валидация количества и содержимого
    if #commands == 0 then
        return nil, "No valid command block found"
    end

    if #commands > 1 then
        return nil, string.format("Multiple command blocks detected (%d). Only one allowed per turn.", #commands)
    end

    return commands[1], nil
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
