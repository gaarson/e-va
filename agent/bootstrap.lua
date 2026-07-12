
local M = {}


--- Runs bootstrap mode: validates prerequisites (URL, model), creates BOOTSTRAPPER agent config,

--- sets up PIPELINE, and calls execute_pipeline.
-- @param config: Configuration table
-- @param ctx: ContextFlow instance
-- @param logger: Logger instance
-- @param execute_pipeline_fn: Function reference to execute_pipeline (from pipeline module)
-- @param run_agent_turn_fn: Function reference to run_agent_turn (from turn module)
-- @param state_file: Path to state file for saving
function M.run_bootstrap(config, ctx, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
    print("\n\27[35m[SYSTEM] Initializing Bootstrapper Meta-Agent with High Creativity...\27[0m")

    os.execute("mkdir -p " .. config.PROJECT_ROOT .. "/.e-va-conf/prompts")

    config.AGENTS = config.AGENTS or {}

    local arch_agent = config.AGENTS.ARCHITECT or {}

    -- Validate bootstrap prerequisites
    local has_url = arch_agent.url or os.getenv("LLM_URL")
    local has_model = arch_agent.model or os.getenv("LLM_MODEL")

    if not has_url then
        logger.error("[BOOTSTRAP] FATAL: No LLM URL found in config.AGENTS.ARCHITECT or env var LLM_URL.")
        print("\n\27[31m[FATAL] Cannot bootstrap: Missing LLM URL. Set config.AGENTS.ARCHITECT.url or export LLM_URL.\27[0m")
        os.exit(1)
    end

    if not has_model then
        logger.error("[BOOTSTRAP] FATAL: No LLM Model found in config.AGENTS.ARCHITECT or env var LLM_MODEL.")
        print("\n\27[31m[FATAL] Cannot bootstrap: Missing LLM Model. Set config.AGENTS.ARCHITECT.model or export LLM_MODEL.\27[0m")
        os.exit(1)
    end

    config.AGENTS.BOOTSTRAPPER = {
        name = "BOOTSTRAPPER",
        url = arch_agent.url or os.getenv("LLM_URL") or "http://127.0.0.1:8000/v1/chat/completions",
        model = arch_agent.model or os.getenv("LLM_MODEL") or "default-model",
        token = arch_agent.token or nil,
        params = {
            stream = true,
            temperature = 0.7,
            max_tokens = 8192,
        },
        prompt_file = "prompts/bootstrapper.md",
        allowed_tools = {"shell"}
    }

    config.PIPELINE = {
        { stage = "BOOTSTRAP_DISCOVERY", agents = { "BOOTSTRAPPER" }, mode = "interactive" }
    }
    execute_pipeline_fn(ctx, config, logger, run_agent_turn_fn, state_file)
end

return M
