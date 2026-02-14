local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    cfg.LIMITS = {
        -- Максимальный размер контекста модели (Hard Limit)
        MAX_CONTEXT = 32000, 
        
        -- Сколько токенов резервируем под ответ модели (Output buffer)
        RESERVED_OUTPUT = 2000,
        
        -- Примерный вес системного промпта и инструкций (Identity + Tool Defs)
        SYSTEM_PROMPT_ESTIMATE = 1500,
        
        -- Баланс памяти: 0.7 = 70% под Файлы, 30% под Историю Чата
        MEMORY_RATIO = 0.7,
        
        -- Эвристика: кол-во символов на 1 токен (для подсчета без токенайзера)
        -- 3.5 - безопасное значение для кода и смешанного текста
        CHARS_PER_TOKEN = 3.5
    }

    local BASE_PARAMS = { stream = true }

    -- TWEAKED PARAMS:
    -- 1. temperature понижена для кодинга (меньше фантазий).
    -- 2. repeat_penalty поднята до 1.2 (убивает циклы в CSS/JSON).
    local PARAMS_BRAIN = {
        max_tokens = 8192, temperature = 0.2, top_p = 0.9,
        repeat_penalty = 1.2, token_healing = true
    }

    local PARAMS_PRECISE = {
        max_tokens = 4096, temperature = 0.1, top_p = 0.1,
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
        model = "Qwen_Qwen3-Coder-30B-Instruct",
        params = merge(BASE_PARAMS, PARAMS_BRAIN)
    }

    cfg.LLM_SCOUT = {
        name = "SCOUT",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen_Qwen3-Coder-30B-Instruct",
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
OBJECTIVE: Locate ALL files necessary for the user's request.

TOOLS:
1. <cmd>list_files</cmd> (View structure)
2. <cmd>read_file:path</cmd> (Load content)
3. <cmd>search:query</cmd> (Grep project)

STRATEGY:
- If you don't know where code is, USE SEARCH.
- If the user asks for UI changes, LOOK FOR RELATED CSS/STYLES files.
- DO NOT read the same file twice. Check your history.
- When you have sufficient context, output <cmd>create_plan</cmd>.
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
You are a Code Patcher Engine (Diff Generator).
CURRENT PHASE: CODING (Task %d of %d).

TARGET FILE: %s
INSTRUCTION: %s

=== CONTEXT STATUS ===
1. The TARGET FILE content is strictly loaded in the **MEMORY** block above.
2. Your ONLY job is to generate a **SEARCH/REPLACE** block to fix it.

=== EXIT STRATEGY (CRITICAL) ===
If the last message in CHAT HISTORY is a "[SUCCESS]" confirmation:
YOU MUST IMMEDIATELY OUTPUT: <cmd>task_complete</cmd>
Do not explain, do not summarize. Just exit.

=== STRICT EXECUTION RULES ===
1. **NO READING**: Do NOT output <cmd>read_file</cmd>. The file is already in Memory. USE IT.
2. **NO LAZY EXITS**: Do NOT output <cmd>task_complete</cmd> UNTIL you have successfully applied the patch (received [SUCCESS]).
3. **EXACT MATCH**: The `<<<<<<< SEARCH` block must be an EXACT COPY of the existing code (including whitespace) from the Memory.
4. **BRIVITY**: Keep the SEARCH block minimal (3-5 lines of context) if possible, to avoid generation loops.

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
