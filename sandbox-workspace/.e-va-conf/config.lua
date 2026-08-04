local M = {}
function M.get()
    return {
        MCP_SERVERS = {
          browser = "npx -y chrome-devtools-mcp@latest --headless=new --isolated --screenshot-format=jpeg --screenshot-quality=70 --screenshot-max-width=1024 --screenshot-max-height=768 --no-usage-statistics --no-performance-crux"
        },
        AGENTS = {
            EXECUTOR = {
                name = "EXECUTOR",
                prompt_file = "prompts/executor.md",
                allowed_tools = {
                    "shell", "read_file", "read_chunk", "create_file", "patch",
                    "search", "explore_tree", "task_complete", "outline",
                    "pin", "unpin", "optimize_context",
                },
                params = {
                    stream = true,
                    temperature = 0.1,
                    top_p = 0.95,
                    max_tokens = 16384,
                    repetition_penalty = 1.05,
                },
                model = "local_model",
            }
        },
        PIPELINE = {
            { stage = "EXECUTE", agents = { "EXECUTOR" }, mode = "sequential" }
        },
        PIPELINE_SETTINGS = {
            MAX_TURNS = 50,
            ABORT_ON_FATAL = true,
        }
    }
end
return M
