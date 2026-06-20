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
        MCP_MAX_OUTPUT_TOKENS = 12000
    }

    cfg.PIPELINE_SETTINGS = {
        MAX_TURNS = 150,
        ABORT_ON_FATAL = true
    }

    cfg.TASKS = {}

    cfg.CREATE_BACKUPS = false
    cfg.PICTURES_DIR = nil -- e.g., '.e-va-conf/pictures'

    local BASE_PARAMS = {
        stream = true,
        stop = nil,
        -- peculative_ngram = true,
        stream_options = { include_usage = true }
    }

    local SAMPLERS = {
        ANALYTICAL = {
            max_tokens = 1024,
            temperature = 0.5,
            -- top_p = 0.95,
            -- top_k = 40,
            -- min_p = 0.02,
            repetition_penalty = 1.05,
            chat_template_kwargs = {enable_thinking = false},
            frequency_penalty = 0.3,
            presence_penalty = 0.3
        },
        ENGINEERING = {
            max_tokens = 1024,
            temperature = 0.1,
            -- top_p = 0.95,
            -- top_k = 40,
            -- min_p = 0.02,
            chat_template_kwargs = {enable_thinking = false},
            repetition_penalty = 1.05,
            frequency_penalty = 0.3,
            presence_penalty = 0.3
        }
    }

    cfg.AGENT_DEFAULTS = {
        url = os.getenv("LLM_URL") or "http://localhost:8000/v1/chat/completions",
        model = os.getenv("LLM_MODEL") or "default-model",
        is_reasoning = false,
        params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ANALYTICAL)
    }

    cfg.AGENTS = {
        ARCHITECT = {
            name = "ARCHITECT",
            -- url = "http://192.168.0.102:8000/v1/chat/completions",
            url = "https://zo-diak.com/ai/v1/chat/completions",
            token = "s1usterseczfHUCeu_+coHk13hemAdyRB7jLwT0TC1R5",
            -- is_reasoning = true,
            model = "Qwopus3.6-27B",
            params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ANALYTICAL),
            prompt_file = "prompts/architect.md",
            allowed_tools = {
              "read_file", "read_chunk", "search", "mcp_browser_*",  "task_complete", "explore_tree", "shell", "delegate_plan", "ask_user", "outline", "pin", "unpin"
            }
        },
        CODER = {
            name = "CODER",
            -- url = "http://192.168.0.102:8000/v1/chat/completions",
            url = "https://zo-diak.com/ai/v1/chat/completions",
            token = "s1usterseczfHUCeu_+coHk13hemAdyRB7jLwT0TC1R5",
            -- is_reasoning = true,
            model = "Qwopus3.6-27B",
            params = utils.deep_merge(BASE_PARAMS, SAMPLERS.ENGINEERING),
            prompt_file = "prompts/coder.md",
            allowed_tools = {
              "patch", "create_file", "shell", "read_file", "read_chunk", "search", "rollback", "cleanup_baks", "task_complete", "outline", "pin", "unpin"
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
