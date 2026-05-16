local os = require("os")

return {
    LIMITS = {
        MAX_CONTEXT = 64000,
        MEMORY_RATIO = 0.7,
    },
    AGENTS = {
        PROJECT_MENTOR = {
            name = "PROJECT_MENTOR",
            url = os.getenv("LLM_URL") or "http://localhost:8000/v1/chat/completions",
            model = "conversational-model",
            is_reasoning = false,
            params = { temperature = 0.5, stream = true, max_tokens = 4096 },
            prompt_file = "prompts/mentor.md",
            allowed_tools = { "explore_tree", "outline", "search", "read_file", "read_chunk", "shell" }
        }
    },
    PIPELINE = {
        { stage = "QNA_SESSION", agents = { "PROJECT_MENTOR" }, mode = "interactive" }
    },
    TASKS = {
        { file = ".", instruction = "Welcome to the E-va Interactive Shell. I am ready to answer your questions about this repository." }
    }
}
