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

    -- [TABBY API / EXLLAMAV2 SAMPLER PROFILES]
    -- ExLlamaV2 pipeline: penalties -> top_k -> min_p -> top_p -> temperature (if temperature_last=true)
    local SAMPLERS = {
        -- Максимальная детерминированность. Идеально для ARCHITECT (анализ, JSON-роутинг).
        ANALYTICAL = {
            max_tokens = 16384,
            temperature = 0.1,
            top_p = 1.0,               -- Отключаем top_p в пользу min_p
            min_p = 0.05,              -- [Tabby] Отсекает длинный хвост мусорных токенов (гораздо лучше top_p)
            smoothing_factor = 0.1,    -- [Tabby] Сглаживает пики уверенности модели (спасает Qwen от зацикливаний)
            repetition_penalty = 1.05,
            token_healing = true,      -- [Tabby] Склеивает разорванные токены (критично для кода)
            temperature_last = true    -- [Tabby] Применяет температуру ПОСЛЕ всех фильтров. Мастхэв.
        },
        -- Баланс креативности и строгости синтаксиса. Идеально для CODER.
        ENGINEERING = {
            max_tokens = 16384,
            temperature = 0.35,        -- Чуть выше для поиска нестандартных решений
            top_p = 1.0,
            min_p = 0.1,               -- Жестче отсекаем бред при высокой температуре
            smoothing_factor = 0.2,
            repetition_penalty = 1.1,
            presence_penalty = 0.1,    -- [Tabby] Заставляет агента использовать новые конструкции
            token_healing = true,
            temperature_last = true
        }
    }

    local function deep_merge(base, specific)
        local res = {}
        for k, v in pairs(base) do res[k] = type(v) == "table" and deep_merge({}, v) or v end
        for k, v in pairs(specific) do res[k] = type(v) == "table" and deep_merge(res[k] or {}, v) or v end
        return res
    end

    cfg.AGENTS = {
        ARCHITECT = {
            name = "ARCHITECT",
            url = "http://192.168.0.116:5000/v1/chat/completions",
            model = "Qwen3.5-35B-A3B-exl3-4.0bpw",
            params = deep_merge(BASE_PARAMS, SAMPLERS.ANALYTICAL),
            prompt_file = "prompts/architect.md",
            allowed_tools = { "read_file", "read_chunk", "search", "list_files", "shell", "delegate_plan", "ask_user", "task_complete", "outline", "pin", "unpin" }
        },
        CODER = {
            name = "CODER",
            url = "http://192.168.0.116:5000/v1/chat/completions",
            model = "Qwen3.5-35B-A3B-exl3-4.0bpw",
            params = deep_merge(BASE_PARAMS, SAMPLERS.ENGINEERING),
            prompt_file = "prompts/coder.md",
            allowed_tools = { "patch", "create_file", "shell", "read_file", "read_chunk", "search", "rollback", "cleanup_baks", "task_complete", "outline", "pin", "unpin" }
        }
    }

    cfg.PIPELINE = {
        { stage = "ANALYSIS_AND_PLANNING", agents = { "ARCHITECT" }, mode = "sequential" },
        { stage = "REVIEW_AND_CHAT", agents = { "ARCHITECT" }, mode = "interactive" },
        { stage = "IMPLEMENTATION", agents = { "CODER" }, mode = "sequential" }
    }

    return cfg
end

return M
