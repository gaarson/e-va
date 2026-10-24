local M = {}


--- Runs bootstrap mode: validates prerequisites (URL, model), creates BOOTSTRAPPER agent config,

--- sets up a 3-phase PIPELINE (Discovery -> Interrogation -> Generation), and calls execute_pipeline.
-- @param config: Configuration table
-- @param ctx: ContextFlow instance
-- @param logger: Logger instance
-- @param execute_pipeline_fn: Function reference to execute_pipeline (from pipeline module)
-- @param run_agent_turn_fn: Function reference to run_agent_turn (from turn module)
-- @param state_file: Path to state file for saving
function M.run_bootstrap(config, ctx, logger, execute_pipeline_fn, run_agent_turn_fn, state_file)
    print("\n\27[35m[SYSTEM] Initializing Bootstrapper Meta-Agent (3-Phase Pipeline)...\27[0m")
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
        url = arch_agent.url or os.getenv("LLM_URL"),
        model = arch_agent.model or os.getenv("LLM_MODEL"),
        token = arch_agent.token or nil,
        is_reasoning = true,  -- Enable thinking for complex analysis
        params = {
            stream = true,
            temperature = 0.25,
            max_tokens = 16384,
        },
        prompt_file = "prompts/bootstrapper.md",
        use_selective_multi_stage = true,
        multi_stage_tools = { "create_file" },
        allowed_tools = {
            "shell",
            "explore_tree",
            "read_file",
            "read_chunk",
            "read_files",
            "search",
            "outline",
            "patch",
            "create_file",
            "pin",
            "unpin",
            "optimize_context",
            "task_complete"   -- FIX: was missing (P5)
        }
    }
    -- Override HANDOFF for bootstrap-specific needs
    local handoff = config.HANDOFF or {}
    handoff.enabled = true
    handoff.clear_history = "smart"
    handoff.preserve_task_anchor = true
    handoff.memo_sections = {
        "execution_plan",
        "decisions",
        "files_modified",
        "remaining_tasks",
        "pinned_files"
    }
    handoff.max_memo_tokens = 12000
    handoff.pass_knowledge_base = true
    handoff.pass_pinned_files = true
    handoff.pass_requested_files = true
    handoff.pass_recent_tool_outputs = false
    handoff.auto_load_plan_files = true
    handoff.max_knowledge_base_files = 100
    handoff.pin_plan_targets = true
    handoff.max_delegate_file_tokens = 15000
    handoff.feedback_to_architect = false     -- N/A for bootstrap (no CODER)
    config.HANDOFF = handoff
    config.PIPELINE_SETTINGS = config.PIPELINE_SETTINGS or {}
    config.PIPELINE_SETTINGS.MAX_TURNS = math.max(config.PIPELINE_SETTINGS.MAX_TURNS or 420, 420)
    config.PIPELINE_SETTINGS.ABORT_ON_FATAL = true

    -- 3-PHASE PIPELINE
    config.PIPELINE = {
        {
            stage = "PHASE1_DISCOVERY",
            agents = { "BOOTSTRAPPER" },
            mode = "sequential"   -- Agent explores autonomously, exits via task_complete
        },
        {
            stage = "PHASE2_INTERROGATION",
            agents = { "BOOTSTRAPPER" },
            mode = "interactive"  -- HITL: agent asks, user answers, /go to proceed
        },
        {
            stage = "PHASE3_GENERATION",
            agents = { "BOOTSTRAPPER" },
            mode = "sequential"   -- Agent writes config + prompts, exits via task_complete
        }
    }
    if type(ctx.add_message) == "function" then
        ctx:add_message(
            "BOOTSTRAPPER",
            "user",
            "Begin bootstrap Phase 1: DISCOVERY. Analyze this project thoroughly using your discovery checklist. Do not ask questions yet; explore autonomously and finish the phase with task_complete."
        )
    end

    execute_pipeline_fn(ctx, config, logger, run_agent_turn_fn, state_file)
end

return M