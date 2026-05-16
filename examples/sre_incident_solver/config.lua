local os = require("os")

return {
    AGENTS = {
        SRE_NINJA = {
            name = "SRE_NINJA",
            url = os.getenv("LLM_URL"),
            model = "analytical-model",
            is_reasoning = true,
            params = { temperature = 0.1, max_tokens = 8192 },
            prompt_file = "prompts/sre.md",
            -- Широчайшие привилегии для диагностики
            allowed_tools = { "trace_execution", "shell", "explore_tree", "read_file", "search", "task_complete" }
        }
    },
    PIPELINE = {
        { stage = "DIAGNOSTICS", agents = { "SRE_NINJA" }, mode = "sequential" }
    },
    TASKS = {
        { file = "build/server_bin", instruction = "The binary is returning 500s. Use trace_execution to attach a uprobe to handle_request and find out why it's failing.", max_turns = 20 }
    }
}
