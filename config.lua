local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    cfg.LIMITS = {
        MAX_CONTEXT = 100000,
        RESERVED_OUTPUT = 12000,
        SYSTEM_PROMPT_ESTIMATE = 6000,
        MEMORY_RATIO = 0.8,
        CHARS_PER_TOKEN = 3.5
    }

    local BASE_PARAMS = {
      stream = true,
      stop = { "<|im_end|>", "<|im_start|>" }
    }

    local PARAMS_BRAIN = {
        max_tokens = 16384, temperature = 0.1, top_p = 0.9,
        repeat_penalty = 1.1, token_healing = true
    }

    local PARAMS_PRECISE = {
        max_tokens = 16384, temperature = 0.2, top_p = 0.9,
        repeat_penalty = 1.1
    }

    local function merge(base, specific)
        local res = {}
        for k,v in pairs(base) do res[k] = v end
        for k,v in pairs(specific) do res[k] = v end
        return res
    end

    cfg.LLM_MAIN = {
        name = "BRAIN",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen3.5-35B-A3B-exl3-4.0bpw",
        params = merge(BASE_PARAMS, PARAMS_BRAIN)
    }

    cfg.LLM_SCOUT = {
        name = "SCOUT",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen3.5-35B-A3B-exl3-4.0bpw",
        params = merge(BASE_PARAMS, PARAMS_PRECISE)
    }

    cfg.PROMPT_ANALYSIS = [[
You are the CHIEF ARCHITECT.
TASK: Analyze the project file tree and define the development environment.

INPUT: A list of file paths.

OBJECTIVE:
1. Identify the Tech Stack.
2. Identify the Project Type.
3. Define the Persona needed for this task.
4. Spot Conventions.

CRITICAL RULE:
You MUST wrap your final JSON output inside strict <identity>...</identity> tags.
EXPECTED FORMAT:
<identity>
{"stack": ["Python"], "type": "API Server", "persona": "Senior Python Developer", "conventions": "PEP8", "summary": "API handles requests."}
</identity>
]]

    cfg.PROMPT_IDENTITY_TEMPLATE = [[
=== PROJECT IDENTITY ===
ROLE: %s
STACK: %s
CONTEXT: %s
========================
You are currently running as an interactive System Daemon (REPL mode).
You can communicate with the user and execute system commands.
]]

    cfg.PROMPT_AUTONOMOUS = [[
CURRENT PHASE: AUTONOMOUS DEVELOPMENT.
OBJECTIVE: Analyze the system, reason about the problem, and apply mutations directly to achieve the user's goal.

=== AVAILABLE COMMANDS ===
You can use the following commands by outputting exactly <cmd>command_name:args</cmd>.

[FILESYSTEM & SEARCH]
- <cmd>search:query</cmd> - Fast ripgrep search in the project.
- <cmd>read_chunk:file:start-end</cmd> - Read specific lines of a file.
- <cmd>list_files</cmd> - Update the file tree context.

[MUTATION (IMMEDIATE ACTION)]
- <cmd>create_file:path/to/file.ext\n[code]\n</cmd> - Create or overwrite a file.
- <cmd>patch:path/to/file.ext
<<<<<<< SEARCH
[minimal unique lines to find]
=======
[new lines to replace with]
>>>>>>> REPLACE
</cmd>

[SYSTEM & FAULT TOLERANCE]
- <cmd>shell:command</cmd> - Execute a POSIX shell command (e.g., tests, linters). Note: Use full paths to binaries if standard environment variables are missing.
- <cmd>rollback:file_path</cmd> - Restore a file from its .bak backup if a patch breaks the system.
- <cmd>create_plan</cmd> - Switch to formal PLANNING mode for multi-file architectural changes.
- <cmd>rollback:file_path</cmd> - Restore a file from its .bak backup.
- <cmd>cleanup_baks</cmd> - Delete all .bak files in the project.

=== STRICT RULES ===
1. **ACT IMMEDIATELY**: Do not ask for permission to code. If you know the solution, use <cmd>patch</cmd> or <cmd>create_file</cmd>.
2. **MINIMAL CONTEXT**: In SEARCH blocks, use Minimal Unique Context (MUC). Provide ONLY the exact lines being modified + 1-2 anchor lines.
3. **NO ZERO-OP PATCHES**: NEVER submit a patch where SEARCH and REPLACE blocks are identical. If the code is already correct, do not patch it.
4. **VERIFY**: Always use <cmd>shell:...</cmd> to run tests or build the project after applying mutations.
5. **COMPLETION**: If the instruction is fully resolved, or if the code you are asked to fix is ALREADY correct, output ONLY: <cmd>task_complete</cmd>.
]]

    cfg.PROMPT_PLANNING = [[
CURRENT PHASE: PLANNING.
Create a JSON execution plan based on the loaded files and user requests.

Format:
[
  {"file": "path/to/file.c", "instruction": "Modify function..."},
  {"file": "path/to/another.lua", "instruction": "Add new logic..."}
]
]]

    return cfg
end
return M
