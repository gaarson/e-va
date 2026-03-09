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
        repeat_penalty = 1.2, token_healing = true
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
        -- url = "http://192.168.0.116:5001/v1/chat/completions",
        -- model = "Qwen3.5-9B-exl3-6.0bpw",
        params = merge(BASE_PARAMS, PARAMS_PRECISE)
    }

    cfg.PROMPT_ANALYSIS = [[
You are the CHIEF ARCHITECT.
TASK: Analyze the project file tree and define the development environment.

INPUT: A list of file paths.

OBJECTIVE:
1. Identify the Tech Stack (Languages, Frameworks, Build Tools).
2. Identify the Project Type.
3. Define the Persona needed for this task (e.g., "Senior Python Developer", "Systems C Engineer").
4. Spot Conventions.

CRITICAL RULE:
You MUST wrap your final JSON output inside strict <identity>...</identity> tags.
You may think or reason outside these tags, but INSIDE them, place ONLY a valid, raw JSON object.

EXPECTED FORMAT:
<identity>
{"stack": ["Python", "FastAPI"], "type": "API Server", "persona": "Senior Python Backend Engineer", "conventions": "PEP8, Asyncio", "summary": "Project handles async requests."}
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

    cfg.PROMPT_RESEARCH = [[
CURRENT PHASE: RESEARCH & INTERACTION.
OBJECTIVE: Assist the user, explore the system, or locate relevant code to build a plan.

=== AVAILABLE COMMANDS ===
You can use the following commands by outputting exactly <cmd>command_name:args</cmd>. You can chain multiple commands.

[FILESYSTEM & SEARCH]
- <cmd>search:query</cmd> - Fast ripgrep search in the project.
- <cmd>read_chunk:file:start-end</cmd> - Read specific lines of a file.
- <cmd>list_files</cmd> - Update the file tree context.

[SYSTEM & OS]
- <cmd>shell:command</cmd> - Execute a POSIX shell command.
- <cmd>set_persona:New Role</cmd> - Dynamically change your current identity/role.

[FAULT TOLERANCE]
- <cmd>rollback:file_path</cmd> - Restore a file from its .bak backup.
- <cmd>cleanup_baks</cmd> - Delete all .bak files in the project.

[PHASE TRANSITION (CRITICAL)]
- <cmd>create_plan</cmd> - Use this ONLY when you are ready to generate a strict sequence of code mutations. 
  * IMPORTANT: Direct file mutations are STRICTLY FORBIDDEN here.
  * IMPORTANT: All reading, checking, and verification (e.g., checking configs, verifying docker-compose) MUST be done in THIS phase BEFORE creating a plan.

=== RULES ===
- **CONVERSATION**: If you want to talk to the user or ask for clarification, simply output your text WITHOUT any <cmd> tags.
- **PROHIBITED**: Do not generate raw code for insertion in this phase. Wait for the CODING phase.
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

    cfg.PROMPT_CODING_TEMPLATE = [[
You are an Elite Non-Conversational System Patcher.
CURRENT PHASE: CODING (Task %d of %d).

TARGET FILE: %s
INSTRUCTION: %s

=== STRICT RULES ===
1. **NO EXPLANATIONS**: Output ONLY commands. NO markdown outside of commands.
2. **CREATE FILES**: Use <cmd>create_file:path/to/file.py\n[code]\n</cmd>
3. **EDIT FILES (MINIMAL CONTEXT PATCHING)**: 
   - NEVER copy entire functions or classes into the SEARCH block.
   - Use Minimal Unique Context (MUC). Provide ONLY the exact lines you are modifying, plus 1-2 lines of surrounding code to act as a unique anchor.
   - Example of GOOD patching (saves tokens):
<cmd>patch:path/to/file.py
<<<<<<< SEARCH
    if not user.is_active:
        return False
=======
    if not user.is_active or user.is_banned:
        return False
>>>>>>> REPLACE
</cmd>

=== EXIT STRATEGY ===
If the instruction is fulfilled, output ONLY: <cmd>task_complete</cmd>.
]]
    return cfg
end
return M
