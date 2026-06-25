local M = {}
local os = require("os")
local utils = require("utils")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    cfg.MCP_SERVERS = {}

    cfg.LIMITS = {
        MAX_CONTEXT = 250000,
        RESERVED_OUTPUT = 5000,
        SYSTEM_PROMPT_ESTIMATE = 6000,
        MEMORY_RATIO = 0.8,
        CHARS_PER_TOKEN = 3.5,
        MCP_MAX_OUTPUT_TOKENS = 32000,
    }

    cfg.CONTEXT_FLOW = {
        storage = {
            max_history_messages = 200,
            max_history_tokens = 160000,
            squash_threshold_messages = 150,
            squash_threshold_tokens = 120000,
            dedup_tool_outputs = true,
            include_pinned_in_recency = true,
        },
        context_injection = {
            mode = "append_to_last_user", -- Меняйте на "separate_message" для моделей с коротким контекстом
            recency_block_enabled = true,
            search_digest_enabled = true,
            max_recency_tokens = 4000,
            max_search_digest_tokens = 2000,
        },
        command_flow = {
            strict_parsing = true,
            max_retries = 3,
            auto_squash_on_mutation = true,
            continuation_prompt = "[SYSTEM]: Continue your analysis...",
            reinforcement_interval = 5,
        },
        token_estimation = {
            chars_per_token = 3.5,
            system_prompt_estimate = 6000,
            reserved_output = 5000,
        },

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
            }
        }
    }

    cfg.PIPELINE_SETTINGS = {
        MAX_TURNS = 150,
        ABORT_ON_FATAL = true,
        CONTEXT_INJECTION_MODE = "separate_message" -- "separate_message" or "append_to_last_user"
    }

    cfg.TASKS = {}

    cfg.CREATE_BACKUPS = false
    cfg.PICTURES_DIR = nil -- e.g., '.e-va-conf/pictures'

    local BASE_PARAMS = {
        stream = true,
        stop={ "<|im_end|>", "<|endoftext|>", "</tool_call>" },
        -- stop_token_ids = { 248046, 248044 },
        peculative_ngram = true,
        stream_options = { include_usage = true }
    }

    local SAMPLERS = {
        ANALYTICAL = {
            max_tokens = 32768,
            temperature = 0.2,
            top_p = 0.80,
            top_k = 35,
            -- min_p = 0.02,
            chat_template_kwargs = {enable_thinking = false},
            -- enable_thinking = true,
            frequency_penalty = 0.2
            -- presence_penalty = 0.0
        },
        ENGINEERING = {
            max_tokens = 32768,
            temperature = 0.1,
            top_p = 0.95,
            top_k = 40,
            -- min_p = 0.02,
            chat_template_kwargs = {enable_thinking = false},
            frequency_penalty = 0.2
            -- presence_penalty = 0.0
        }
    }

    cfg.AGENT_DEFAULTS = {
        url = os.getenv("LLM_URL") or "http://localhost:8000/v1/chat/completions",
        model = os.getenv("LLM_MODEL") or "default-model",
        is_reasoning = false,
        params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ANALYTICAL),
        -- reasoning_config = {
        --     auto_toggle = true, -- Разрешить агенту самому включать/выключать мысли
        --     complexity_threshold = 0.7, -- Если оценка сложности > 0.7, включаем мысли
        --     max_thought_tokens = 2048 -- Лимит токенов на один блок мыслей
        -- }
    }

    -- Добавь в возвращаемую таблицу cfg:
    cfg.OPTIMIZER_AGENT = {
        name = "OPTIMIZER",
        -- url = "https://zo-diak.com/ai/v1/chat/completions",
        url = "http://192.168.0.102:8000/v1/chat/completions",
        -- model = "Qwen3.5-27B-AWQ",
        model = "gemma4-12B",
        token = "s1usterseczfHUCeu_+coHk13hemAdyRB7jLwT0TC1R5",
        is_reasoning = true,
        params = {
            stream = true,
            temperature = 0.1,
            chat_template_kwargs = {enable_thinking = false},
            max_tokens = 2048
        }
    }
    cfg.AGENTS = {
        ARCHITECT = {
            name = "ARCHITECT",
            -- url = "http://192.168.0.102:8000/v1/chat/completions",
            url = "https://zo-diak.com/ai/v1/chat/completions",
            token = "s1usterseczfHUCeu_+coHk13hemAdyRB7jLwT0TC1R5",
            -- is_reasoning = true,
            model = "Qwen3.5-27B-AWQ",
            -- model = "gemma4-12B",
            params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ANALYTICAL),
            prompt_file = "prompts/architect.md",
            allowed_tools = {
              "read_file", "read_files", "read_chunk", "search", "mcp_browser_*", "explore_tree", "shell", "delegate_plan", "ask_user", "outline", "pin", "unpin",
              "optimize_context", -- "task_complete"
            }
        },
        CODER = {
            name = "CODER",
            url = "https://zo-diak.com/ai/v1/chat/completions",
            -- url = "http://192.168.0.102:8000/v1/chat/completions",
            token = "s1usterseczfHUCeu_+coHk13hemAdyRB7jLwT0TC1R5",
            -- is_reasoning = true,
            model = "Qwen3.5-27B-AWQ",
            -- model = "gemma4-12B",
            params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ENGINEERING),
            prompt_file = "prompts/coder.md",
            allowed_tools = {
              "patch", "create_file", "shell", "read_file", "read_chunk", "search", "rollback", "cleanup_baks", "task_complete", "outline", "pin", "unpin", "optimize_context"
            }
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
