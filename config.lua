local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    -- === LLM PARAMS ===
    local BASE_PARAMS = { stream = true }
    
    -- Main Brain (Creative & Logic)
    local PARAMS_BRAIN = {
        max_tokens = 8192, temperature = 0.2, top_p = 0.9,
        repeat_penalty = 1.1, token_healing = true
    }

    -- Scout/Analyzer (Precise)
    local PARAMS_PRECISE = {
        max_tokens = 4096, temperature = 0.0, top_p = 0.1,
        repeat_penalty = 1.2
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
        model = "Qwen_Qwen3-Coder-30B-Instruct", -- Пример
        params = merge(BASE_PARAMS, PARAMS_BRAIN)
    }

    cfg.LLM_SCOUT = {
        name = "SCOUT",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen_Qwen3-Coder-30B-Instruct",
        params = merge(BASE_PARAMS, PARAMS_PRECISE)
    }

    -- === PROMPTS ===

    -- 1. ANALYSIS PROMPT (BOOTSTRAP)
    cfg.PROMPT_ANALYSIS = [[
You are the CHIEF ARCHITECT. 
TASK: Analyze the project file tree and define the development environment.

INPUT: A list of file paths.

OBJECTIVE:
1. Identify the **Tech Stack** (Languages, Frameworks, Build Tools).
2. Identify the **Project Type** (Monorepo, Microservice, SPA, Script, Library).
3. Define the **Persona** needed for this task (e.g., "Senior React Developer", "Systems C Engineer", "DevOps Specialist").
4. Spot **Conventions** (naming, folder structure).

OUTPUT: Return ONLY a JSON object. No markdown, no text.
{
  "stack": ["Lua", "C", "Make"],
  "type": "Embedded Scripting",
  "persona": "Senior Systems Engineer (Lua/C)",
  "conventions": "Modular Lua architecture, C bindings separate",
  "summary": "This is a high-performance agent system written in Lua with C extensions."
}
]]

    -- 2. DYNAMIC SYSTEM HEADER (Injected into other prompts)
    cfg.PROMPT_IDENTITY_TEMPLATE = [[
=== PROJECT IDENTITY ===
ROLE: %s
STACK: %s
CONTEXT: %s
========================
]]

    -- 3. RESEARCH PROMPT
    cfg.PROMPT_RESEARCH = [[
CURRENT PHASE: RESEARCH.
OBJECTIVE: Locate ALL files necessary for the user's request.
Use <cmd>list_files</cmd> (already scanned) and <cmd>read_file:path</cmd>.
Do not assume file contents. Read them.
When you have sufficient context, output <cmd>create_plan</cmd>.
]]

    -- 4. PLANNING PROMPT
    cfg.PROMPT_PLANNING = [[
CURRENT PHASE: PLANNING.
Create a JSON execution plan based on the loaded files.
Format:
[{"file": "path", "instruction": "detail"}, ...]
]]

    -- 5. CODING PROMPT
    cfg.PROMPT_CODING_TEMPLATE = [[
You are a Code Patcher Engine (Diff Generator).
CURRENT PHASE: CODING (Task %d of %d).

TARGET FILE: %s
INSTRUCTION: %s

=== CONTEXT STATUS ===
1. The TARGET FILE content is strictly loaded in the **MEMORY** block above.
2. The file currently **DOES NOT MATCH** the instruction.
3. Your ONLY job is to generate a **SEARCH/REPLACE** block to fix it.

=== STRICT EXECUTION RULES ===
1. **NO READING**: Do NOT output <cmd>read_file</cmd>. The file is already in Memory. USE IT.
2. **NO LAZY EXITS**: Do NOT output <cmd>task_complete</cmd> until you have output a valid <<<<<<< SEARCH block and confirmed the patch.
3. **EXACT MATCH**: The `<<<<<<< SEARCH` block must be an EXACT COPY of the existing code (including whitespace) from the Memory.
4. **THINKING PROCESS**: Start with "Thinking:" to locate the exact lines to change.

=== REQUIRED OUTPUT FORMAT ===
Thinking:
I found the lines... I will replace them with...

File: %s
<<<<<<< SEARCH
    original code line 1
    original code line 2
=======
    modified code line 1
    modified code line 2
>>>>>>> REPLACE
]]

    return cfg
end
return M
