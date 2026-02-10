local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."
    cfg.API_URL = os.getenv("API_URL") or "http://192.168.0.116:5000/v1/chat/completions"
    cfg.API_MODEL = os.getenv("API_MODEL") or "Qwen_Qwen2.5-Coder-32B-Instruct"

    cfg.GENERATION_PARAMS = {
        max_tokens = 4096,
        temperature = 0.2,
        min_p = 0.05,
        top_k = 40,
        dry_multiplier = 0.8,
        dry_base = 1.75,
        dry_allowed_length = 2,
        dry_sequence_breakers = "[\n\",;.!?]",
        token_healing = true,
        add_bos_token = true,
        ban_eos_token = false,
    }

    cfg.REGEX_RESEARCH = [[(<cmd>(list_files|read_file:[a-zA-Z0-9_./\-]+(:[a-zA-Z0-9_\-\s]+)?|map_file:[a-zA-Z0-9_./\-]+|start_coding)</cmd>\s*)+]]

    cfg.PROMPT_RESEARCH = [[
You are a Senior Systems Architect. Phase: RESEARCH.
Goal: Map out the files needed for the task.

RULES:
1. OUTPUT ONLY COMMANDS. No chat. No explanations.
2. Use <cmd>list_files</cmd> to find files.
3. Reading Ranges: Use <cmd>read_file:path/to/file:10-50</cmd>.
   - NOTE: Do NOT write "start_line" or "lines". Just use the numbers: ":10-50".
4. When ready, output <cmd>start_coding</cmd>.
]]

    cfg.PROMPT_CODING = [[
You are a Senior Developer. Phase: CODING.
Goal: Apply changes to the files found in Research phase.

CRITICAL RULES:
1. NO <cmd> TAGS ALLOWED IN THIS PHASE. Do NOT use <cmd>patch</cmd>.
2. Start your response IMMEDIATELY with the "File:" line.
3. Use standard SEARCH/REPLACE blocks.
4. If you are finished, output ONLY: <cmd>finished</cmd> (This is the ONLY allowed command).

FORMAT:
File: path/to/file.ext
<<<<<<< SEARCH
old code line
=======
new code line
>>>>>>> REPLACE
]]

    return cfg
end
return M
