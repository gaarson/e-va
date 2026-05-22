local os = require("os")

return {
    AGENTS = {
        BACKEND_ENGINEER = {
            name = "BACKEND_ENGINEER",
            url = os.getenv("LLM_URL") or "http://localhost:8000/v1/chat/completions",
            model = "backend-optimized-model",
            is_reasoning = true,
            params = { temperature = 0.2, stream = true },
            prompt_file = "prompts/backend.md",
            allowed_tools = { "patch", "create_file", "shell", "read_file", "search", "task_complete" }
        },
        FRONTEND_ENGINEER = {
            name = "FRONTEND_ENGINEER",
            url = os.getenv("LLM_URL") or "http://localhost:8000/v1/chat/completions",
            model = "frontend-optimized-model",
            is_reasoning = true,
            params = { temperature = 0.4, stream = true },
            prompt_file = "prompts/frontend.md",
            -- Frontend сфокусирован на UI
            allowed_tools = { "patch", "create_file", "shell", "read_file", "search", "task_complete" }
        }
    },
    PIPELINE = {
        { stage = "PARALLEL_IMPLEMENTATION", agents = { "BACKEND_ENGINEER", "FRONTEND_ENGINEER" }, mode = "parallel" },
        { stage = "MERGE_REVIEW", agents = { "BACKEND_ENGINEER" }, mode = "interactive" }
    },
    TASKS = {
        { file = "api/routes.go", instruction = "Add POST /api/v1/metrics endpoint.", max_turns = 10 },
        { file = "ui/Dashboard.tsx", instruction = "Create a fetch hook for /api/v1/metrics and render a chart.", max_turns = 15 }
    }
}
