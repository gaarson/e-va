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

-- Парсинг: ищем ровно один блок между маркерами
function M:parse_command(text)
    if not text or type(text) ~= "string" then return nil, "Empty response" end
    -- Гибкий паттерн: игнорирует любые пробелы/переносы вокруг команды
    local pattern = string.format("%s%s(.-)%s%s", self.cmd_start, "%s*", "%s*", self.cmd_end)
    local match = text:match(pattern)

    if not match then
        -- Fallback: if no closed block, look for just the start marker
        local fallback_pattern = self.cmd_start .. "%s*(.*)"
        match = text:match(fallback_pattern)

        if not match or match == "" then
            return nil, "No valid command block found"
        end
    end

    match = utils.trim(match)
    if match == "" then
        return nil, "Empty command payload"
    end
    -- Проверка на множественные команды
    local count = 0
    for _ in text:gmatch(self.cmd_start) do count = count + 1 end
    if count > 1 then
        return nil, "Multiple command blocks detected. Only one allowed per turn."
    end
    return match, nil
end

-- Валидация: существует ли такой тул?
function M:validate_command(cmd)
    local tool_name = cmd:match("^([^:]+)")
    if not tool_name then
        return false, "Invalid command format. Expected: tool_name:arguments"
    end
    tool_name = utils.trim(tool_name)

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

    local tool_name = cmd:match("^([^:]+)")

    -- 3. Специальная обработка ask_user
    if tool_name == "ask_user" then
        self.state = M.STATES.WAITING_USER
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
