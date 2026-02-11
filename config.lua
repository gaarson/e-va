local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."


    local BASE_PARAMS = {
        max_tokens = 8192,
        temperature = 0.0,
        top_p = 0.95,
        stream = false
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

    local function merge(base, specific)
        local res = {}
        for k,v in pairs(base) do res[k] = v end
        for k,v in pairs(specific) do res[k] = v end
        return res
    end

 
    
  
    cfg.LLM_MAIN = {
        name = "BRAIN (Main)",
        url = "http://192.168.0.116:5000/v1/chat/completions",
        model = "Qwen_Qwen3-Coder-30B-A3B-Instruct-EXL3-4.0bpw", 
        params = merge(BASE_PARAMS, PARAMS_TABBY)
    }

 
    cfg.LLM_SCOUT = {
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
You are the Build Scheduler.
CURRENT PHASE: PLANNING.

OBJECTIVE:
Create a JSON execution plan based on the RESEARCH.

INSTRUCTIONS:
1. Return a JSON list of tasks.
2. Include BOTH Frontend and Backend files if necessary.
3. Output ONLY the valid JSON block.

FORMAT:
[
  {
    "file": "backend/service/models.py",
    "instruction": "Add 'new_field' to the Product model."
  },
  {
    "file": "frontend/ui/Table.jsx",
    "instruction": "Display 'new_field' in the table columns."
  }
]
]]

    cfg.PROMPT_CODING_TEMPLATE = [[
You are a Senior Developer.
CURRENT PHASE: CODING (Task %d of %d).

TARGET FILE: %s
TASK: %s

CRITICAL RULES:
1. The file content is loaded in MEMORY.
2. Output a SEARCH/REPLACE block to apply the changes.
3. The SEARCH block must contain an EXACT COPY of the lines from the file (whitespace is ignored, but content must match).
4. If you fail to match, check the file content in MEMORY again.
5. If the file is already correct, output <cmd>task_complete</cmd>.

FORMAT:
File: path/to/file.ext
<<<<<<< SEARCH
    original line 1
    original line 2
=======
    modified line 1
    modified line 2
>>>>>>> REPLACE
]]

    return cfg
end
return M
