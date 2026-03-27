local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    cfg.LIMITS = {
        MAX_CONTEXT = 100000,
        RESERVED_OUTPUT = 12000,
        SYSTEM_PROMPT_ESTIMATE = 6000,
        MEMORY_RATIO = 0.8,
        CHARS_PER_TOKEN = 3.5
    }

    local BASE_PARAMS = {
      stream = true,
      stop = { "<|im_end|>", "<|im_start|>" }
    }

    local PARAMS_ARCHITECT = {
        max_tokens = 16384, temperature = 0.1, top_p = 0.9,
        repeat_penalty = 1.1, token_healing = true
    }

    local PARAMS_CODER = {
        max_tokens = 16384, temperature = 0.2, top_p = 0.9,
        repeat_penalty = 1.1
    }

    local function merge(base, specific)
        local res = {}
        for k,v in pairs(base) do res[k] = v end
        for k,v in pairs(specific) do res[k] = v end
        return res
    end

    -- [РЕЕСТР АГЕНТОВ]
    cfg.AGENTS = {
        ARCHITECT = {
            name = "ARCHITECT",
            url = "http://192.168.0.116:5000/v1/chat/completions",
            model = "Qwen3.5-35B-A3B-exl3-4.0bpw",
            params = merge(BASE_PARAMS, PARAMS_ARCHITECT),
            prompt_file = "prompts/architect.md",
            -- Архитектор только читает и планирует
            allowed_tools = { "read_file", "read_chunk", "search", "list_files", "delegate_plan" }
        },
        CODER = {
            name = "CODER",
            url = "http://192.168.0.116:5000/v1/chat/completions",
            model = "Qwen3.5-35B-A3B-exl3-4.0bpw",
            params = merge(BASE_PARAMS, PARAMS_CODER),
            prompt_file = "prompts/coder.md",
            -- Кодер мутирует код и запускает тесты
            allowed_tools = { "patch", "create_file", "shell", "read_file", "search", "rollback", "cleanup_baks", "task_complete" }
        }
    }

    -- [ОРКЕСТРАЦИЯ ПАЙПЛАЙНА]
    cfg.PIPELINE = {
        { stage = "ANALYSIS_AND_PLANNING", agents = { "ARCHITECT" }, mode = "sequential" },
        { stage = "IMPLEMENTATION", agents = { "CODER" }, mode = "sequential" }
        -- Если потребуется параллелизм в будущем (например, два ревьюера):
        -- { stage = "REVIEW", agents = { "SECURITY_AUDITOR", "PERFORMANCE_AUDITOR" }, mode = "parallel" }
    }

    return cfg
end
return M
