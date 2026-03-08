local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    cfg.LIMITS = {
        -- Максимальный размер контекста модели (Hard Limit)
        MAX_CONTEXT = 100000,
        -- Сколько токенов резервируем под ответ модели (Output buffer)
        RESERVED_OUTPUT = 12000,
        -- Примерный вес системного промпта и инструкций (Identity + Tool Defs)
        SYSTEM_PROMPT_ESTIMATE = 6000,
        -- Баланс памяти: 0.7 = 70% под Файлы, 30% под Историю Чата
        MEMORY_RATIO = 0.8,
        -- Эвристика: кол-во символов на 1 токен (для подсчета без токенайзера)
        -- 3.5 - безопасное значение для кода и смешанного текста
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
        -- model = "Qwen_Qwen3-Coder-30B-Instruct",
        params = merge(BASE_PARAMS, PARAMS_BRAIN)
    }

    cfg.LLM_SCOUT = {
        name = "SCOUT",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen3.5-35B-A3B-exl3-4.0bpw",
        -- model = "Qwen3.5-9B-exl3-4.0bpw",
        -- model = "Qwen_Qwen3-Coder-30B-Instruct",
        params = merge(BASE_PARAMS, PARAMS_PRECISE)
    }

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

    cfg.PROMPT_IDENTITY_TEMPLATE = [[
=== PROJECT IDENTITY ===
ROLE: %s
STACK: %s
CONTEXT: %s
========================
]]

    cfg.PROMPT_RESEARCH = [[
CURRENT PHASE: RESEARCH.
OBJECTIVE: Locate relevant code and understand the architecture without reading full files.

=== CONTEXT STATUS ===
The FILE TREE is ALREADY loaded in the System Prompt above.
DO NOT use <cmd>list_files</cmd> unless the tree is empty.

=== STRATEGY (GREP-FIRST APPROACH) ===
1. **SEARCH FIRST**: Use <cmd>search:query</cmd> to find specific function definitions, variable usages, or text classes.
   - Example: <cmd>search:class PdfGeneration</cmd>
   - Example: <cmd>search:def save_preset</cmd>

2. **INSPECT CONTEXT**: Once you have line numbers from search, use <cmd>read_chunk:file:start-end</cmd>.
   - Read +/- 20 lines around the match to understand the logic.
   - SAVE TOKENS: Do NOT read the whole file if you only need one function.

3. **ANALYZE IMPORTS**: If you need to see dependencies, read the top of the file:
   - <cmd>read_chunk:src/main.js:1-50</cmd>

=== RULES ===
- **PROHIBITED**: Do NOT use <cmd>read_file</cmd> (full read) unless the file is very small (< 100 lines) or absolutely necessary.
- **AGGREGATE**: You can issue multiple commands in one response (e.g., search for 3 different terms).
- **EXIT**: When you have enough information to build a plan, output <cmd>create_plan</cmd>.
]]

    cfg.PROMPT_PLANNING = [[
CURRENT PHASE: PLANNING.
Create a JSON execution plan based on the loaded files.

RULES:
1. If modifying a component (.jsx/.tsx), check if its STYLES (.css/.scss) also need modification.
2. If so, create a SEPARATE task for the CSS file. Do not assume you can edit two files in one task.

Format:
[
  {"file": "path/to/Component.jsx", "instruction": "Modify HTML structure..."},
  {"file": "path/to/Component.css", "instruction": "Add new styles..."}
]
]]

    cfg.PROMPT_CODING_TEMPLATE = [[
You are a Non-Conversational Code Patcher.
CURRENT PHASE: CODING (Task %d of %d).

TARGET FILE: %s
INSTRUCTION: %s

=== EXIT STRATEGY (CHECK MEMORY FIRST) ===
1. Look at the TARGET FILE in MEMORY below.
2. **IF THE CODE IS ALREADY IMPLEMENTED/FIXED:**
   Output ONLY: <cmd>task_complete</cmd>
   (Do NOT generate a patch. Do NOT output "File: ...". Just exit.)

=== STRICT RULES ===
1. **NO TALKING**: Do not explain your logic.
2. **OUTPUT ONLY**: Start with `File: ...` then the search block.
3. **ONE FILE ONLY**: Edit ONLY the TARGET FILE.

=== RESPONSE FORMAT ===
File: %s
<<<<<<< SEARCH
    original line 1
=======
    modified line 1
>>>>>>> REPLACE
]]
    return cfg
end
return M
