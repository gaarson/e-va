local M = {}
local os = require("os")
local utils = require("utils")
-- Cache for .env file values (fallback when os.getenv is empty)
local _env_cache = {}
--- Resolve an environment variable, falling back to .env file parsing.
-- Tries os.getenv first, then parses .env files from known paths.
local function resolve_env(key, default)
    local val = os.getenv(key)
    if val and val ~= "" then
        return val
    end
    -- Check cache first
    if _env_cache[key] then
        return _env_cache[key]
    end
    -- Parse .env files from known paths
    local env_paths = {
        os.getenv("ENV_PATH"),
        os.getenv("AGENT_HOME") and os.getenv("AGENT_HOME") .. "/.env",
        os.getenv("PROJECT_ROOT") and os.getenv("PROJECT_ROOT") .. "/.env",
        "./.env",
    }
    for _, path in ipairs(env_paths) do
        if path then
            local f = io.open(path, "r")
            if f then
                for line in f:lines() do
                    line = line:gsub("^%s+", ""):gsub("%s+$", "")
                    if line ~= "" and not line:match("^#") then
                        local k, v = line:match("^([A-Za-z_][A-Za-z0-9_]*)=(.*)")
                        if k and v then
                            v = v:gsub('^"', ''):gsub('"$', ''):gsub("^'", ''):gsub("'", "$")
                            _env_cache[k] = v
                        end
                    end
                end
                f:close()
            end
        end
    end
    val = _env_cache[key]
    if val and val ~= "" then
        return val
    end
    return default
end
local function get_api_key()
    local key = os.getenv("LLM_API_KEY")
    if not key or key == "" then
        key = os.getenv("OPENAI_API_KEY")
    end
    if not key or key == "" then
        return "UNSET_LLM_API_KEY"
    end
    return key
end
function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    cfg.MCP_SERVERS = {}

    -- FOR DOCKER
    -- MCP_SERVERS = {
    --     browser = "npx -y chrome-devtools-mcp@latest --headless=new --isolated --screenshot-format=jpeg --screenshot-quality=70 --screenshot-max-width=1024 --screenshot-max-height=768 --no-usage-statistics --no-performance-crux"
    -- }

    cfg.LIMITS = {
        MAX_CONTEXT = 160000,
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
            squash_threshold_tokens = 100000,
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
            dedup_exceptions = { "task_complete*", "delegate_plan*", "shell*", "mcp_browser_*", "search*", "read_file*", "read_chunk*" },
        },
        token_estimation = {
            chars_per_token = 3.5,
            system_prompt_estimate = 6000,
            reserved_output = 5000,
        },
        -- Compression configuration
        compression = {
            enabled = true,
            zone1_size = 5,        -- Recent messages: verbatim
            zone2_size = 10,        -- Middle messages: light compression
            max_tool_output_bytes = 8192,
            compress_thinking_blocks = true,
            preserve_errors = true,
            llm_summarization = {
                enabled = true,
                min_message_length = 3000,  -- Only summarize very long messages with LLM
                rate_limit_seconds = 600,
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
                context_injection = { mode = "append_to_last_user", max_recency_tokens = 50000 },
                command_flow = { auto_squash_on_mutation = true, reinforcement_interval = 3 },
                storage = { max_history_tokens = 40000 }
            }
        }
    }

    cfg.PIPELINE_SETTINGS = {
        MAX_TURNS = 420,
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
        pass_recent_tool_outputs = false,   -- Передавать результаты последних инструментов
        auto_load_plan_files = true,       -- Автоматически подгружать файлы из плана
        max_knowledge_base_files = 100,    -- Increased from 50 to 100
        pin_plan_targets = true,           -- NEW: Automatically pin all execution plan target files
        max_delegate_file_tokens = 15000,  -- NEW: Max tokens per file for delegate_plan auto-loading
        -- NEW: Enable CODER to send error summaries back to ARCHITECT for plan adjustment
        feedback_to_architect = true,
        feedback_sections = { "tasks_completed", "tasks_failed", "errors_encountered", "plan_deviations", "recommendations" },
        max_feedback_tokens = 8192,
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
    -- ========================================================================
    -- PICTURES_DIR: Directory for screenshots and images.
    --
    -- Pipeline architecture (entry point → processing → injection):
    --   1. agent/turn.lua: Calls ctx:load_images() every turn.
    --   2. context/images.lua: Orchestrates loading, filtering, trimming, injection,
    --      and token estimation. Calls utils.load_images_from_dir() for I/O.
    --   3. utils/images.lua: Low-level I/O, compression (ffmpeg/ImageMagick),
    --      base64 encoding, hashing, dimension detection.
    --
    -- Full pipeline per turn:
    --   scan → compress → base64 encode → age-filter → budget-filter → dedup →
    --   inject into last user message as multipart content.
    -- ========================================================================
    cfg.PICTURES_DIR = ".e-va-conf/pictures"
    -- ========================================================================
    -- IMAGE_CONFIG: Configuration for image processing pipeline.
    -- ========================================================================
    cfg.IMAGE_CONFIG = {
        -- max_images_per_turn: Hard cap on images sent per turn.
        -- Used by trim_images() Phase 2 (count budget) and add_image() as rejection threshold.
        -- When exceeded, oldest images (head of array) are removed first.
        max_images_per_turn = 10,
        -- max_images_base64_bytes: Total base64 size budget for all images (default 4MB).
        -- Used by load_images() budget filter AND trim_images() Phase 3 (byte budget).
        -- Images are sorted newest-first; oldest are dropped when budget is exceeded.
        -- Reduced to 4MB since compressed images are significantly smaller than originals.
        max_images_base64_bytes = 4 * 1024 * 1024,
        -- auto_purge_after_turn: When true, M.purge_images() is called after each turn,
        -- clearing ctx.images, ctx.images_loaded, and ctx.last_sent_image_hashes.
        -- Default false preserves visual context across turns for continuity.
        -- For manual purge, call M.purge_images().
        auto_purge_after_turn = false,
        -- max_image_age_hours: Images older than this (checked via stat mtime in load_images())
        -- are silently skipped during directory scan. Default 168 hours (7 days).
        -- Prevents loading stale screenshots no longer relevant to the current task.
        max_image_age_hours = 168,
        -- tokens_per_base64_byte: NOTE — this coefficient is currently UNUSED for actual
        -- token estimation. Actual estimation in inject_images_into_messages() uses the
        -- OpenAI tile-based model:
        --   low-res (short side < 768px, both sides <= 2048px) = 85 tokens flat
        --   high-res = 85 + 170 * num_512x512_tiles (capped at 4x4 = 16 tiles)
        -- This field exists as a fallback/reserved parameter for future use.
        tokens_per_base64_byte = 0.004,
        -- max_image_dimension: Maximum pixel dimension for the longest side during compression.
        -- Passed to compress_image() as max_dim. Images exceeding this on any axis are
        -- resized via ffmpeg (primary) or ImageMagick (fallback). Quality is hardcoded at 60.
        -- Files < 200KB or already within bounds are skipped. Value 512px chosen for
        -- aggressive token economy (Option A).
        max_image_dimension = 512,
    }

    -- Source .env file early to populate cache for AGENT_DEFAULTS
    resolve_env("LLM_BASE_URL", "")
    local BASE_PARAMS = {
        stream = true,
    }
    local SAMPLERS = {
        ANALYTICAL = {
            max_tokens = 16384,
            temperature = 0.2,
            top_p = 0.95,
            top_k = 60,
            -- min_p = 0.02,
            chat_template_kwargs = {enable_thinking = true},
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
        url = resolve_env("LLM_BASE_URL", "http://localhost:8000/v1/chat/completions"),
        model = resolve_env("LLM_MODEL", "default-model"),
        token = get_api_key(),
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
        url = resolve_env("LLM_BASE_URL", "http://localhost:8000/v1/chat/completions"),
        token = get_api_key(),
        -- is_reasoning = true,
        model = resolve_env("LLM_MODEL", "local_model"),
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
            url = resolve_env("LLM_BASE_URL", "http://localhost:8000/v1/chat/completions"),
            token = get_api_key(),
            is_reasoning = true,
            model = resolve_env("LLM_MODEL", "local_model"),
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
            url = resolve_env("LLM_BASE_URL", "http://localhost:8000/v1/chat/completions"),
            token = get_api_key(),
            -- is_reasoning = true,
            model = resolve_env("LLM_MODEL", "local_model"),
            params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ENGINEERING),
            use_selective_multi_stage = true,
            multi_stage_tools = { "create_file", "patch" },
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