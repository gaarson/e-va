-- config.lua
local M = {}
local os = require("os")

function M.get()
    local cfg = {}
    cfg.PROJECT_ROOT = os.getenv("PROJECT_ROOT") or "."
    cfg.API_URL = os.getenv("API_URL") or "http://192.168.0.116:5000/v1/chat/completions"
    cfg.API_MODEL = os.getenv("API_MODEL") or "Qwen_Qwen2.5-Coder-32B-Instruct" 
    cfg.TEMPERATURE = 0.0 -- Ноль градусов. Максимальная строгость.

    cfg.PROMPT_RESEARCH = [[
You are a Senior Systems Architect. Phase: RESEARCH.
Goal: Map out the files needed for the task.

RULES:
1. NO patching allowed yet.
2. Use <cmd>list_files</cmd> to find files.
3. Use <cmd>read_file:path</cmd> sparingly.
4. When you know WHICH files to edit, output <cmd>start_coding</cmd>.
]]

    cfg.PROMPT_CODING = [[
You are a Senior Developer. Phase: CODING.
Goal: Apply changes to the files found in Research phase.

CRITICAL RULES:
1. DO NOT re-read files that are already in 'MEMORY'.
2. If the file is already correct, DO NOT patch it just to "touch" it. Skip it.
3. WHEN FINISHED: Output ONLY <cmd>finished</cmd>. DO NOT write a summary. DO NOT say "I have updated...". JUST EXIT.

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
