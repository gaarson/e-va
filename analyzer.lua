local M = {}
local json = require("JSON")
local logger = require("logger")
local utils = require("utils")

function M.run(ctx, llm_handler)
    local config = ctx.config
    logger.info("PHASE: ANALYSIS (Bootstrapping Identity)")

    -- 1. Scan Files (if not done)
    if ctx.file_tree == "(Not scanned yet)" or ctx.file_tree == nil then
        logger.info("Scanning file structure...")
        local tree = utils.list_files_recursive(config.PROJECT_ROOT)
        -- Гарантируем, что результат - строка
        ctx:update_file_tree(tree or "(Scan failed)")
    end

    -- 2. Prepare Prompt
    -- ЗАЩИТА ОТ NIL: (ctx.file_tree or "...")
    local tree_safe = ctx.file_tree or "(Empty File Tree)"
    local messages = {
        { role = "system", content = config.PROMPT_ANALYSIS },
        { role = "user", content = "Analyze this File Tree:\n" .. tree_safe }
    }

    -- 3. Call LLM
    io.write("\27[36m>>> AI (ANALYSIS): Analyzing project structure...\27[0m\n")
    local response, err = llm_handler.send_request(config.LLM_SCOUT, messages)

    if not response then
        logger.error("Analysis Failed", err)
        -- Не падаем, а используем дефолтную личность
        ctx.identity = { persona = "Developer", stack = {"Unknown"}, summary = "Fallback mode" }
        return false
    end

    local raw = llm_handler.extract_content(response)
    local json_str = raw:match("```json%s*(.-)%s*```") or raw:match("({.*})")

    if json_str then
        local status, identity = pcall(function() return json:decode(json_str) end)
        if status and identity then
            ctx.identity = identity
            logger.info("Identity Established", identity)
            print(string.format("\n\27[32m[IDENTITY]\27[0m Role: %s | Type: %s", identity.persona, identity.type))
            return true
        end
    end

    logger.warn("Analysis failed to parse JSON. Proceeding with default persona.")
    ctx.identity = { persona = "System Engineer", stack = {"Unknown"}, summary = "Manual override" }
    return false
end

return M
