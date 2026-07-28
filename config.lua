local M = {}
local os = require("os")
local utils = require("utils")
local function get_api_key()
    local key = os.getenv("LLM_API_KEY")
    if not key or key == "" then
        error("FATAL: LLM_API_KEY environment variable must be set")
    end
    return key
end
function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    cfg.MCP_SERVERS = {}

    cfg.LIMITS = {
        MAX_CONTEXT = 200000,
        RESERVED_OUTPUT = 5000,
        SYSTEM_PROMPT_ESTIMATE = 6000,
        MEMORY_RATIO = 0.8,
        CHARS_PER_TOKEN = 3.5,
        MCP_MAX_OUTPUT_TOKENS = 16000,
    }

    cfg.CONTEXT_FLOW = {
        storage = {
            max_history_messages = 100,
            max_history_tokens = 50000,
            squash_threshold_messages = 80,
            squash_threshold_tokens = 120000,
            dedup_tool_outputs = true,
            include_pinned_in_recency = true,
        },
        context_injection = {
            mode = "append_to_last_user", -- Меняйте на "separate_message" для моделей с коротким контекстом
            recency_block_enabled = true,
            search_digest_enabled = true,
            max_recency_tokens = 20000,
            max_search_digest_tokens = 20000,
        },
        command_flow = {
            strict_parsing = true,
            max_retries = 3,
            auto_squash_on_mutation = true,
            continuation_prompt = "check maybe you stuck or what maybe command invalid, dont forget optimize context sometime",
            reinforcement_interval = 5,
            -- Commands exempt from dedup. Patterns ending with '*' are treated as prefix wildcards
            -- (e.g., "mcp_browser_*" exempts all mcp_browser_* variants like mcp_browser_go_to, mcp_browser_click, etc.)
            -- "shell*" exempts all shell:* commands (shell:ls, shell:npm run build, etc.)
            -- "task_complete*" exempts task_complete and task_complete:... variants
            -- "delegate_plan*" exempts delegate_plan and delegate_plan:... variants
            dedup_exceptions = { "task_complete*", "delegate_plan*", "shell*", "mcp_browser_*", "search*", "read_chunk*" },
        },
        token_estimation = {
            chars_per_token = 3.5,
            system_prompt_estimate = 6000,
            reserved_output = 5000,
        },
        -- Compression configuration
        compression = {
            enabled = true,
            zone1_size = 10,        -- Recent messages: verbatim
            zone2_size = 20,        -- Middle messages: light compression
            max_tool_output_bytes = 2048,
            compress_thinking_blocks = true,
            preserve_errors = true,
            llm_summarization = {
                enabled = true,
                min_message_length = 5000,  -- Only summarize very long messages with LLM
                rate_limit_seconds = 300,
                max_summaries_per_turn = 3,
            },
        },
        model_profiles = {
            reasoning = {
                context_injection = { mode = "separate_message" },
                command_flow = { strict_parsing = true, max_retries = 5 },
                storage = { squash_threshold_tokens = 90000 }
            },
            coding = {
                context_injection = { mode = "append_to_last_user", max_recency_tokens = 20000 },
                command_flow = { auto_squash_on_mutation = true, reinforcement_interval = 3 },
                storage = { max_history_tokens = 40000 }
            }
        }
    }

    cfg.PIPELINE_SETTINGS = {
        MAX_TURNS = 150,
        ABORT_ON_FATAL = true,
        CONTEXT_INJECTION_MODE = "separate_message" -- "separate_message" or "append_to_last_user"
    }

    cfg.HANDOFF = {
        enabled = true,
        clear_history = "smart",
        preserve_task_anchor = true,
        memo_sections = { "execution_plan", "decisions", "files_modified", "remaining_tasks", "pinned_files" },
        max_memo_tokens = 12000,
        pass_knowledge_base = true,        -- Передавать все файлы из базы знаний
        pass_pinned_files = true,          -- Передавать зафиксированные файлы
        pass_requested_files = true,       -- Передавать файлы, запрошенные на предыдущем этапе
        pass_recent_tool_outputs = true,   -- Передавать результаты последних инструментов
        auto_load_plan_files = true,       -- Автоматически подгружать файлы из плана
        max_knowledge_base_files = 100,    -- Increased from 50 to 100
        pin_plan_targets = true,           -- NEW: Automatically pin all execution plan target files
        max_delegate_file_tokens = 15000,  -- NEW: Max tokens per file for delegate_plan auto-loading
        -- NEW: Enable CODER to send error summaries back to ARCHITECT for plan adjustment
        feedback_to_architect = true,
        feedback_sections = { "tasks_completed", "tasks_failed", "errors_encountered", "plan_deviations", "recommendations" },
        max_feedback_tokens = 3000,
    }
    -- Circuit breaker configuration for tool failures
    cfg.CIRCUIT_BREAKER = {
        enabled = true,
        threshold = 3,           -- Number of consecutive failures before triggering
        cooldown_turns = 5,      -- Number of turns to wait before retrying the failed tool
        warning_message = true,  -- Whether to inject a warning message to the agent
    }
    cfg.TASKS = {}

    cfg.CREATE_BACKUPS = false
    cfg.PICTURES_DIR = ".e-va-conf/pictures"

    cfg.IMAGE_CONFIG = {
        max_images_per_turn = 10,
        max_images_base64_bytes = 4 * 1024 * 1024,  -- Reduced to 4MB since compressed images are much smaller
        auto_purge_after_turn = false,  -- Images persist across turns; use M:purge_images() manually if needed
        tokens_per_base64_byte = 0.004,  -- For OpenAI vision: low res (<50KB) = 85 tokens, high res = variable (~0.004/byte)
        max_image_dimension = 512,  -- Max pixels on longest side for compression (Option A: aggressive token economy)
        max_image_age_hours = 168  -- Skip images older than 24 hours
    }

    local BASE_PARAMS = {
        stream = true,
        -- peculative_ngram = true,
        -- stream_options = { include_usage = true }
    }

    local SAMPLERS = {
        ANALYTICAL = {
            max_tokens = 16384,
            temperature = 0.2,
            top_p = 0.95,
            top_k = 60,
            -- min_p = 0.02,
            chat_template_kwargs = {enable_thinking = false},
            -- enable_thinking = true,
            -- frequency_penalty = 0.2
            repetition_penalty = 1.05
        },
        ENGINEERING = {
            max_tokens = 16384,
            temperature = 0.1,
            top_p = 0.95,
            top_k = 60,
            -- min_p = 0.02,
            chat_template_kwargs = {enable_thinking = false},
            -- presence_penalty = 0.0
            repetition_penalty = 1.05
        }
    }

    cfg.AGENT_DEFAULTS = {
        url = os.getenv("LLM_URL") or "http://localhost:8000/v1/chat/completions",
        model = os.getenv("LLM_MODEL") or "default-model",
        is_reasoning = false,
        min_max_tokens = 1024,
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
            url = os.getenv("LLM_BASE_URL"),
            token = get_api_key(),
            -- is_reasoning = true,
            model = os.getenv("LLM_MODEL") or "Qwen3.5-27B-AWQ",
        -- model = "local_model",
        -- is_reasoning = true,
        params = {
            stream = true,
            temperature = 0.1,
            chat_template_kwargs = {enable_thinking = false},
            max_tokens = 16384
        }
    }

    cfg.AGENTS = {
        ARCHITECT = {
            name = "ARCHITECT",
            url = os.getenv("LLM_BASE_URL"),
            token = get_api_key(),
            -- is_reasoning = true,
            model = os.getenv("LLM_MODEL") or "Qwen3.5-27B-AWQ",
            params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ANALYTICAL),
            prompt_file = "prompts/architect.md",
            -- use_selective_multi_stage = true,
            -- multi_stage_tools = { "delegate_plan" },
            allowed_tools = {
              "read_file",
              -- "read_files", 
              "read_chunk", 
              "search", 
              "mcp_browser_*", 
              "explore_tree", 
              "shell", 
              "delegate_plan", 
              "ask_user", 
              "outline", 
              "pin", 
              "unpin",
              "optimize_context",
            }
        },
        CODER = {
            name = "CODER",
            url = os.getenv("LLM_BASE_URL"),
            token = get_api_key(),
            -- is_reasoning = true,
            model = os.getenv("LLM_MODEL") or "Qwen3.5-27B-AWQ",
            params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ENGINEERING),
            -- use_selective_multi_stage = true,
            -- multi_stage_tools = { "create_file", "patch" },
            prompt_file = "prompts/coder.md",
            allowed_tools = {
              "patch",
              "create_file",
              "shell",
              "read_file",
              "mcp_browser_*", 
              "read_chunk",
              "search",
              "task_complete",
              "outline",
              "pin",
              "unpin",
              "optimize_context",
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