local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."

    local BASE_PARAMS = {
        max_tokens = 8192,
        temperature = 0.1,
        top_p = 0.95,
        stream = true
    }

    local PARAMS_TABBY = {
        min_p = 0.05,
        token_healing = true,
        add_bos_token = true,
        ban_eos_token = false,
        dry_multiplier = 0.8,
        dry_base = 1.75,
        dry_allowed_length = 2,
        dry_sequence_breakers = {"\n", ":", "\"", ".", ";", "!", "?", ">"}
    }

    local PARAMS_LLAMA = {
        repeat_penalty = 1.15,  -- Классический штраф за повторы (1.0 = выкл)
        presence_penalty = 0.0, -- Штраф за появление токена
        frequency_penalty = 0.0,-- Штраф за частоту
        tfs_z = 1.0,            -- Tail Free Sampling (1.0 = выкл)
        mirostat = 0,           -- 0 = выкл, 2 = Mirostat v2 (хорош для длинных текстов)
        mirostat_tau = 5.0,
        mirostat_eta = 0.1,
        ignore_eos = false      -- Аналог ban_eos_token, но для llama.cpp
    }

    local function merge(base, specific)
        local res = {}
        for k,v in pairs(base) do res[k] = v end
        for k,v in pairs(specific) do res[k] = v end
        return res
    end

    cfg.LLM_MAIN = {
        -- name = "BRAIN (Main)",
        -- url = "http://192.168.0.116:5001/v1/chat/completions",
        -- model = "glm-4.7-flash-claude-4.5-opus.iq4_xs.gguf",
        -- params = merge(BASE_PARAMS, PARAMS_LLAMA)
        name = "BRAIN (Main)",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen_Qwen3-Coder-30B-A3B-Instruct-EXL3-4.0bpw", 
        params = merge(BASE_PARAMS, PARAMS_TABBY)
    }

    cfg.LLM_SCOUT = {
        -- name = "SCOUT (Research)",
        -- url = "http://192.168.0.116:5001/v1/chat/completions",
        -- model = "glm-4.7-flash-claude-4.5-opus.iq4_xs.gguf",
        -- params = merge(BASE_PARAMS, PARAMS_LLAMA)
        name = "SCOUT (Research)",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen_Qwen3-Coder-30B-A3B-Instruct-EXL3-4.0bpw",
        params = merge(BASE_PARAMS, PARAMS_TABBY)
    }

    cfg.REGEX_RESEARCH = nil
    cfg.REGEX_PLANNING = nil
    cfg.REGEX_CODING = nil

    cfg.PROMPT_RESEARCH = [[
You are a Senior System Architect.
CURRENT PHASE: RESEARCH.

OBJECTIVE:
Locate ALL code required for the task. You must understand the data flow between Backend and Frontend.

RULES:
1. **THINK FIRST**: Briefly analyze the situation before issuing a command.
2. DO NOT read the same file twice. Check "MEMORY" first.
3. USE <cmd>search:text</cmd> to find specific definitions.
4. When you understand the full scope, output <cmd>create_plan</cmd>.

TOOLS:
- <cmd>list_files</cmd> : See file structure (uses ripgrep).
- <cmd>search:text_query</cmd> : Grep files (uses ripgrep).
- <cmd>read_file:path</cmd> : Read file content.
- <cmd>create_plan</cmd> : Done researching. Switch to Planning.

EXAMPLE:
Thinking: I need to find where the Product model is defined to see the new fields.
<cmd>search:class Product</cmd>
]]

    cfg.PROMPT_PLANNING = [[
You are the Execution Planner.
CURRENT PHASE: PLANNING.

GOAL: Create a precise JSON plan to implement the changes found during RESEARCH.

CRITICAL INSTRUCTION:
Break down tasks into ATOMIC file modifications. Do not group unrelated files.

FORMAT:
[
  {
    "file": "frontend/components/Table.jsx",
    "instruction": "Inject 'new_field' column into the table header and body."
  },
  {
    "file": "frontend/components/Table.css",
    "instruction": "Add 'overflow-x: auto' to the .table-container class."
  }
]
]]

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
