-- context/builder.lua


-- Context building and prompt assembly extracted from context_flow.lua.

-- All functions take ctx (the context_flow instance) as the first argument.


local M = {}


local utils = require("utils")
local config_mod = require("context.config")
local strategies = require("context.strategies")
local images = require("context.images")



-- ============================================================================

-- CONTEXT BUILDING

-- ============================================================================


function M.build_context(ctx, agent_name, agent_cfg, available_tokens)

    local system_prompt = M.get_system_prompt(ctx, agent_cfg)

    local messages = { { role = "system", content = system_prompt } }

    local chat_buffer = {}

    local current_cost = 0

    local history = ctx.history[agent_name] or {}

    local estimate = function(t) return ctx.estimate_tokens(t, agent_cfg) end


    -- 1. Estimate size of mandatory blocks

    local recency = M.get_recency_block(ctx)

    local recency_cost = estimate(recency)

    local tools_manifest = require("tool_registry").generate_tool_manifest(agent_cfg.allowed_tools, agent_cfg)

    local manifest_cost = estimate(tools_manifest)


    -- 2. Calculate real budget for history

    local overhead = recency_cost + manifest_cost + math.ceil(#system_prompt / ctx.flow_config.token_estimation.chars_per_token)

    local chat_budget = math.max(0, available_tokens - overhead - math.floor(available_tokens * 0.1)) -- 10% reserve


    -- 3. Load history from the end

    for i = #history, 1, -1 do

        local msg = history[i]

        local cost = estimate(msg.content)

        if current_cost + cost < chat_budget then

            table.insert(chat_buffer, 1, { role = msg.role, content = msg.content })

            current_cost = current_cost + cost

        else break end

    end


    -- 4. Inject recency

    local inject_fn = strategies.INJECTION_STRATEGIES[ctx.flow_config.context_injection.mode] or strategies.INJECTION_STRATEGIES.append_to_last_user

    inject_fn(chat_buffer, recency, "")


    -- Add handoff or initiation

    if #history == 0 then

        local init_msg = ctx.handoff_memo and

            "[SYSTEM: HANDOFF MEMO]\n" .. ctx.handoff_memo or

            "[SYSTEM: INITIATION]\nReview context and proceed."

        table.insert(chat_buffer, { role = "user", content = init_msg })

    end


    -- Normalize roles for API (some don't like system in the middle)

    for _, msg in ipairs(chat_buffer) do

        local role = msg.role == "system" and "user" or msg.role

        table.insert(messages, { role = role, content = msg.content })

    end


    -- Image injection (OpenAI Format) with deduplication
    local tokens_per_byte = (ctx.config.IMAGE_CONFIG and ctx.config.IMAGE_CONFIG.tokens_per_base64_byte) or 0.004
    local messages, total_image_tokens = images.inject_images_into_messages(ctx, messages, tokens_per_byte)
    -- Fix for API: if last is assistant, add continuation
    if #messages > 1 and messages[#messages].role == "assistant" then
        table.insert(messages, { role = "user", content = ctx.flow_config.command_flow.continuation_prompt })
    end
    local total_tokens = estimate(system_prompt) + current_cost + recency_cost + manifest_cost + total_image_tokens


    return {

        messages = messages,

        total_tokens = total_tokens,

        system_prompt = system_prompt,

        chat_buffer = chat_buffer

    }

end



-- ============================================================================

-- RECENCY BLOCK

-- ============================================================================


function M.get_recency_block(ctx)

    local parts = {}

    -- System state

    if ctx.execution_plan and #ctx.execution_plan > 0 then

        table.insert(parts, "<execution_plan>" .. M.get_plan_text(ctx) .. "</execution_plan>")

    end

    if #ctx.last_actions > 0 then

        table.insert(parts, "<last_actions>" .. M.get_actions_text(ctx) .. "</last_actions>")

    end

    -- Build set of execution_plan target files for full-content display

    local plan_target_files = {}

    if ctx.execution_plan and #ctx.execution_plan > 0 then

        for _, task in ipairs(ctx.execution_plan) do

            if task.file then

                local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)

                plan_target_files[rel_path] = true

            end

        end

    end

    if ctx.flow_config.storage.include_pinned_in_recency then

        for path,_ in pairs(ctx.pinned_files) do

            if not ctx.turn_requested_files[path] and ctx.knowledge_base[path] then

                local content = ctx.knowledge_base[path]

                local is_plan_target = plan_target_files[path]

                -- For files that are BOTH pinned AND in execution_plan: show FULL content

                -- For other pinned files: apply truncation only if promoted

                if not is_plan_target and ctx.promoted_files and ctx.promoted_files[path] then

                    local max_display_len = 200

                    if #content > max_display_len then

                        content = content:sub(1, max_display_len) .. "\n...[TRUNCATED: Full content moved to conversation history]..."

                    end

                end

                -- Plan targets always get full content regardless of promoted status

                table.insert(parts, string.format("<file_context path=\"%s\" status=\"PINNED\">\n%s\n</file_context>",

                    path, content))

            end

        end

    end

    return table.concat(parts, "\n")

end



-- ============================================================================

-- SEARCH DIGEST

-- ============================================================================


function M.get_search_digest(ctx, max_tokens)

    local div = ctx.flow_config.token_estimation.chars_per_token

    local buf = {"\n=== SEARCH DIGEST ==="}

    local tokens = 0

    for q, res in pairs(ctx.search_history) do

        table.insert(buf, "--- Query: " .. q .. " ---")

        for line in res:gmatch("[^\r\n]+") do

            local clean = line:match("[:-]%d+[:-]%s*(.+)$") or line

            clean = clean:gsub("^%s+", ""):gsub("%s+", " ")

            if clean ~= "" then

                table.insert(buf, clean)

                tokens = tokens + math.ceil(#clean / div)

                if tokens >= max_tokens then

                    table.insert(buf, "... [TRUNCATED] ...")

                    return table.concat(buf, "\n")

                end

            end

        end

    end

    return table.concat(buf, "\n")

end



-- ============================================================================

-- SYSTEM PROMPT

-- ============================================================================


function M.get_system_prompt(ctx, agent_cfg)

    local prompt_text = M.load_prompt(ctx, agent_cfg.prompt_file)

    local tools_manifest = require("tool_registry").generate_tool_manifest(agent_cfg.allowed_tools, agent_cfg)

    local directives = M.get_engine_directives(ctx, agent_cfg)

    return prompt_text .. "\n" .. directives .. "\n" .. tools_manifest

end



-- ============================================================================

-- ENGINE DIRECTIVES

-- ============================================================================


function M.get_engine_directives(ctx, agent_cfg)

    local has_delegate = false

    local has_complete = false


    for _, t in ipairs(agent_cfg.allowed_tools or {}) do

        if t == "delegate_plan" or t == "*" then has_delegate = true end

        if t == "task_complete" or t == "*" then has_complete = true end

    end


    local rule = has_delegate and has_complete and "Use `task_complete` to advance." or

                 has_delegate and "Use `delegate_plan` to advance." or

                 has_complete and "Use `task_complete` to finish." or "Analyze and respond."


    -- Multi-stage info

    local multi_stage_note = ""

    if agent_cfg.use_selective_multi_stage and agent_cfg.multi_stage_tools and #agent_cfg.multi_stage_tools > 0 then

        local tool_list = table.concat(agent_cfg.multi_stage_tools, ", ")

        multi_stage_note = string.format("\n3. MULTI-STAGE: Tools [%s] go through Intent->Generate->Review. Others execute directly.", tool_list)

    end


    return string.format("\n==================================================\nENGINE DIRECTIVES:\n1. PIPELINE: %s\n2. ONE COMMAND PER TURN. Use batch tools if needed.%s\n==================================================", rule, multi_stage_note)

end



-- ============================================================================

-- LOAD PROMPT

-- ============================================================================


function M.load_prompt(ctx, path)

    if not path then return "You are an AI assistant." end

    local paths = {}

    -- Support absolute paths: try directly first

    if path:sub(1, 1) == "/" then

        table.insert(paths, path)

    end

    table.insert(paths, ctx.config.PROJECT_ROOT .. "/.e-va-conf/" .. path)

    table.insert(paths, ctx.config.PROJECT_ROOT .. "/" .. path)

    local agent_home = os.getenv("AGENT_HOME")

    if agent_home then table.insert(paths, agent_home .. "/" .. path) end

    for _, p in ipairs(paths) do

        local c = utils.read_file_range(p)

        if c then return c end

    end

    return "You are an AI assistant."

end



-- ============================================================================

-- PLAN TEXT

-- ============================================================================


function M.get_plan_text(ctx)

    if not ctx.execution_plan or #ctx.execution_plan == 0 then return "" end

    local t = ""

    for i, task in ipairs(ctx.execution_plan) do

        local mark = (i < ctx.current_task_index) and "[x]" or (i == ctx.current_task_index) and "[>]" or "[ ]"

        t = t .. string.format("%s Step %d: %s -> %s\n", mark, i, tostring(task.file or "?"), tostring(task.instruction or "?"))

    end

    return t

end



-- ============================================================================

-- ACTIONS TEXT

-- ============================================================================


function M.get_actions_text(ctx)

    if #ctx.last_actions == 0 then return "" end

    local t = "\n=== LAST ACTIONS ===\n"

    for _, a in ipairs(ctx.last_actions) do t = t .. string.format("- %s: %s\n", a.type, a.summary) end

    return t

end



-- ============================================================================

-- FILE CONTEXT

-- ============================================================================


function M.get_file_context(ctx, file_info)

    local content = ctx.knowledge_base[file_info.path]

    if not content then return "" end

    local raw_lines = utils.read_lines_raw(content)

    local content_display = table.concat(raw_lines, "\n")

    local indented_content = content_display

    local status = "READ_ONLY"

    if file_info.is_target then status = "TARGET"

    elseif file_info.is_pinned then status = "PINNED"

    elseif file_info.is_modified then status = "RECENTLY_MODIFIED" end

    return string.format("\n<file_context path=\"%s\" status=\"%s\">\n\n%s\n\n</file_context>\n",

        file_info.path, status, indented_content)

end



-- ============================================================================

-- MEMORY BLOCK

-- ============================================================================


function M.get_memory_block(ctx, max_tokens)

    max_tokens = max_tokens or 10000

    local current_tokens = 0

    local memory_parts = {}

    if next(ctx.pinned_files) then

        local pinned_text = "\n=== PINNED FILES ===\n"

        for path, _ in pairs(ctx.pinned_files) do pinned_text = pinned_text .. string.format("- %s\n", path) end

        local cost = ctx.estimate_tokens(pinned_text)

        if current_tokens + cost < max_tokens then table.insert(memory_parts, pinned_text); current_tokens = current_tokens + cost end

    end

    local changes_text = M.get_changes_summary(ctx)

    local cost = ctx.estimate_tokens(changes_text)

    if current_tokens + cost < max_tokens then table.insert(memory_parts, changes_text); current_tokens = current_tokens + cost end

    local insights_text = M.get_insights_summary(ctx)

    cost = ctx.estimate_tokens(insights_text)

    if current_tokens + cost < max_tokens then table.insert(memory_parts, insights_text); current_tokens = current_tokens + cost end

    return table.concat(memory_parts, "\n")

end



-- ============================================================================

-- REPORT

-- ============================================================================


function M.get_report(ctx, agent_name)

    local search_summary = ""

    local count = 0

    for _,_ in pairs(ctx.search_history) do count = count + 1 end

    if count > 0 then search_summary = string.format("\n## SEARCH HISTORY\n(Cached %d queries)\n", count) end

    local tree_content = ctx.file_tree or "(empty)"

    if #tree_content > 30000 then

        tree_content = tree_content:sub(1, 30000) .. "\n... [TREE TRUNCATED - USE ||| COMMAND |||\nexplore_tree:path:depth\n||| END_COMMAND ||| TO NAVIGATE]"

    end

    local tree_block = string.format("## PROJECT STRUCTURE (Current View)\n```text\n%s\n```\n", tree_content)

    return string.format("# PROJECT CONTEXT\nRoot: %s\n---\n%s%s", ctx.flow_config.PROJECT_ROOT, tree_block, search_summary)

end



-- ============================================================================

-- SYSTEM STATE XML

-- ============================================================================


function M.build_system_state_xml(ctx)

    local xml = "<system_state>"

    if ctx.task_summary and ctx.task_summary ~= "" then

        xml = xml .. "\n  <task_summary>" .. ctx.task_summary .. "\n  </task_summary>"

    end

    if ctx.execution_plan and #ctx.execution_plan > 0 then

        xml = xml .. "\n  <execution_plan>" .. M.get_plan_text(ctx) .. "\n  </execution_plan>"

    end

    if #ctx.last_actions > 0 then

        xml = xml .. "\n  <last_actions>" .. M.get_actions_text(ctx) .. "\n  </last_actions>"

    end

    return xml .. "\n</system_state>"

end



-- ============================================================================

-- RECENCY TOOL OUTPUTS

-- ============================================================================


function M.get_recency_tool_outputs(ctx)

    if not ctx.recent_tool_outputs or #ctx.recent_tool_outputs == 0 then return "" end

    local parts = {"\n<recent_tool_outputs>"}

    for _, tool_out in ipairs(ctx.recent_tool_outputs) do

        table.insert(parts, string.format("\n  <tool_output name=\"%s\">\n%s\n  </tool_output>", tool_out.tool, (tool_out.output or "")))

    end

    table.insert(parts, "\n</recent_tool_outputs>")

    return table.concat(parts)

end



-- ============================================================================

-- IMAGE CONTENT PARTS

-- ============================================================================


function M.get_image_content_parts(ctx)

    if not ctx.images or #ctx.images == 0 then return {} end

    local parts = {}

    for _, img in ipairs(ctx.images) do

        table.insert(parts, { type = "image_url", image_url = { url = "data:" .. img.mime_type .. ";base64," .. img.base64_data } })

    end

    return parts

end



-- ============================================================================

-- CHANGES SUMMARY

-- ============================================================================


function M.get_changes_summary(ctx)

    local text = "\n=== CHANGES SUMMARY ===\n"

    for path, state in pairs(ctx.file_states) do

        if state == "RECENTLY_MODIFIED" then text = text .. string.format("- %s: modified\n", path) end

    end

    return text

end



-- ============================================================================

-- INSIGHTS SUMMARY

-- ============================================================================


function M.get_insights_summary(ctx)

    if not next(ctx.search_history) then return "" end

    local text = "\n=== SEARCH INSIGHTS ===\n"

    for query, result in pairs(ctx.search_history) do

        local lines = {}

        for line in result:gmatch("[^\r\n]+") do

            local pure = line:match("[:-]%d+[:-]%s*(.+)$") or line

            local compressed = pure:gsub("^%s+", ""):gsub("%s+", " ")

            if compressed ~= "" then table.insert(lines, compressed) end

        end

        text = text .. string.format("- %s: %s\n", query, table.concat(lines, "; "))

    end

    return text

end



-- ============================================================================

-- RECENT THOUGHTS TEXT

-- ============================================================================


function M.get_recent_thoughts_text(ctx)

    if not ctx.thoughts or #ctx.thoughts == 0 then return "" end

    local text = "\n=== RECENT THOUGHTS ===\n"

    local start_idx = math.max(1, #ctx.thoughts - 140)

    for i = start_idx, #ctx.thoughts do

        text = text .. string.format("-----\n%s\n", ctx.thoughts[i].content)

    end

    return text

end



return M