-- context/handoff.lua
-- Handoff/stage transition extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.
local M = {}
local utils = require("utils")
local history = require("context.history")
local builder = require("context.builder")
local json = require("JSON")
-- ============================================================================
-- GENERATE HANDOFF MEMO
-- ============================================================================
function M.generate_handoff_memo(ctx, agent_name, agent_cfg)
    local cfg = ctx.config.HANDOFF or {}
    local sections = cfg.memo_sections or { "execution_plan", "decisions", "files_modified", "remaining_tasks" }
    local max_tokens = cfg.max_memo_tokens or 4000
    local div = ctx.flow_config.token_estimation.chars_per_token
    local parts = {}
    local tokens = 0
    table.insert(parts, string.format("<handoff_memo agent=\"%s\">", agent_name))
    for _, sec in ipairs(sections) do
        if sec == "execution_plan" then
            local plan_text = builder.get_plan_text(ctx)
            if plan_text ~= "" then
                table.insert(parts, "<execution_plan>" .. plan_text .. "</execution_plan>")
            end
        elseif sec == "decisions" or sec == "last_actions" then
            local actions_text = builder.get_actions_text(ctx)
            if actions_text ~= "" then
                table.insert(parts, "<decisions>" .. actions_text .. "</decisions>")
            end
        elseif sec == "files_modified" then
            local modified = {}
            for path, state in pairs(ctx.file_states) do
                if state == "MODIFIED" or state == "CREATED" then
                    table.insert(modified, path)
                end
            end
            if #modified > 0 then
                table.insert(parts, "<files_modified>" .. table.concat(modified, ", ") .. "</files_modified>")
            end
        elseif sec == "remaining_tasks" then
            if ctx.execution_plan and #ctx.execution_plan > 0 then
                local remaining = {}
                for i = ctx.current_task_index, #ctx.execution_plan do
                    table.insert(remaining, string.format("Step %d: %s -> %s", i, ctx.execution_plan[i].file, ctx.execution_plan[i].instruction))
                end
                if #remaining > 0 then
                    table.insert(parts, "<remaining_tasks>" .. table.concat(remaining, "\n") .. "</remaining_tasks>")
                end
            end
        elseif sec == "knowledge_base_keys" then
            local keys = {}
            for path, _ in pairs(ctx.knowledge_base) do
                table.insert(keys, path)
            end
            if #keys > 0 then
                table.insert(parts, "<knowledge_base_keys>" .. table.concat(keys, ", ") .. "</knowledge_base_keys>")
            end
        elseif sec == "pinned_files" then
            local pins = {}
            for path, _ in pairs(ctx.pinned_files) do
                table.insert(pins, path)
            end
            if #pins > 0 then
                table.insert(parts, "<pinned_files>" .. table.concat(pins, ", ") .. "</pinned_files>")
            end
        elseif sec == "agent_summary" then
            table.insert(parts, "<agent_summary>[PROMPT: Please summarize your work in this stage]</agent_summary>")
        end
        tokens = tokens + math.ceil(#sec / div)
        if tokens >= max_tokens then break end
    end
    -- Add structured JSON handoff payload
    local json_payload = {
        from_agent = agent_name,
        execution_plan = {},
        current_task_index = ctx.current_task_index or 1,
        files_modified = {},
        pinned_files = {},
        knowledge_base_count = 0,
        errors_encountered = {},
        decisions = {},
        last_actions = {},
        remaining_tasks = 0
    }
    -- Execution plan
    if ctx.execution_plan and #ctx.execution_plan > 0 then
        for i, task in ipairs(ctx.execution_plan) do
            local status = "pending"
            if i < ctx.current_task_index then status = "done"
            elseif i == ctx.current_task_index then status = "active" end
            table.insert(json_payload.execution_plan, {
                step = i,
                file = tostring(task.file or "?"),
                instruction = tostring(task.instruction or "?"),
                status = status
            })
        end
        json_payload.remaining_tasks = #ctx.execution_plan - ctx.current_task_index + 1
    end
    -- Files modified
    for path, state in pairs(ctx.file_states) do
        if state == "MODIFIED" or state == "CREATED" then
            table.insert(json_payload.files_modified, { path = path, state = state })
        end
    end
    -- Pinned files
    for path, _ in pairs(ctx.pinned_files) do
        table.insert(json_payload.pinned_files, path)
    end
    -- Knowledge base count
    local kb_count = 0
    for _, _ in pairs(ctx.knowledge_base) do kb_count = kb_count + 1 end
    json_payload.knowledge_base_count = kb_count
    -- Last actions
    for _, a in ipairs(ctx.last_actions) do
        table.insert(json_payload.last_actions, { type = a.type, summary = a.summary })
    end
    -- Decisions from last_actions
    for _, a in ipairs(ctx.last_actions) do
        if a.type == "DECISION" then
            table.insert(json_payload.decisions, a.summary)
        end
    end
    -- Errors from recent tool outputs
    for _, tool_out in ipairs(ctx.recent_tool_outputs) do
        if tool_out.output and (tool_out.output:match("[Ee][Rr][Rr][Oo][Rr]") or tool_out.output:match("[Ff][Aa][Ii][Ll][Ee][Dd]")) then
            table.insert(json_payload.errors_encountered, {
                message = tool_out.output:sub(1, 200),
                tool = tool_out.tool
            })
        end
    end
    local json_str = json:encode(json_payload)
    table.insert(parts, "<handoff_json>" .. json_str .. "</handoff_json>")
    table.insert(parts, "</handoff_memo>")
    return table.concat(parts, "\n")
end
-- ============================================================================
-- CLEAR HISTORY FOR STAGE
-- ============================================================================
function M.clear_history_for_stage(ctx, strategy)
    if strategy == "none" or strategy == nil then return end
    if strategy == "full" then
        ctx.history = {}
        ctx.thoughts = {}
        ctx.last_actions = {}
        ctx.recent_tool_outputs = {}
        ctx.turn_requested_files = {}
    elseif strategy == "per_stage" then
        local keep_count = 10
        for agent_name, msgs in pairs(ctx.history) do
            if #msgs > keep_count then
                ctx.history[agent_name] = { unpack(msgs, #msgs - keep_count + 1, #msgs) }
            end
        end
        ctx.thoughts = {}
        ctx.recent_tool_outputs = {}
        ctx.turn_requested_files = {}
    end
end
-- ============================================================================
-- SET HANDOFF MEMO
-- ============================================================================
function M.set_handoff_memo(ctx, memo)
    ctx.handoff_memo = memo
end
-- ============================================================================
-- SYNC FILES
-- ============================================================================
function M.sync_files(ctx)
    local updated_files = {}
    local root = ctx.config.PROJECT_ROOT or "."
    for path, old_content in pairs(ctx.knowledge_base) do
        local full_path = root .. "/" .. path
        local new_content = utils.read_file_range(full_path)
        if new_content and new_content ~= old_content then
            ctx.knowledge_base[path] = new_content
            table.insert(updated_files, path)
        end
    end
    return updated_files
end
-- ============================================================================
-- GET HANDOFF FILES
-- ============================================================================
function M.get_handoff_files(ctx)
    local files_to_pass = {}
    local max_files = ctx.config.HANDOFF.max_knowledge_base_files or 50
    -- 1. Files from plan (priority)
    if ctx.execution_plan then
        for _, task in ipairs(ctx.execution_plan) do
            if task.file then
                local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)
                if ctx.knowledge_base[rel_path] then
                    files_to_pass[rel_path] = true
                end
            end
        end
    end
    -- 2. Pinned files
    if ctx.config.HANDOFF.pass_pinned_files then
        for path, _ in pairs(ctx.pinned_files) do
            if ctx.knowledge_base[path] then
                files_to_pass[path] = true
            end
        end
    end
    -- 3. Requested files
    if ctx.config.HANDOFF.pass_requested_files then
        for path, _ in pairs(ctx.turn_requested_files) do
            if ctx.knowledge_base[path] then
                files_to_pass[path] = true
            end
        end
    end
    -- 4. Remaining knowledge base files (if needed)
    if ctx.config.HANDOFF.pass_knowledge_base then
        for path, _ in pairs(ctx.knowledge_base) do
            if not files_to_pass[path] then
                files_to_pass[path] = true
                if #files_to_pass >= max_files then break end
            end
        end
    end
    return files_to_pass
end
-- ============================================================================
-- INJECT HANDOFF FILES
-- ============================================================================
function M.inject_handoff_files(ctx, agent_name)
    local files_to_pass = M.get_handoff_files(ctx)
    if not next(files_to_pass) then return end
    local parts = {}
    local hist = history.get_history(ctx, agent_name)
    local handoff_cfg = ctx.config.HANDOFF or {}
    local lazy_mode = handoff_cfg.lazy_mode or false
    local max_handoff_file_size = handoff_cfg.max_handoff_file_size or 50000
    -- Build set of execution_plan target files for prioritization
    local plan_target_files = {}
    if ctx.execution_plan and #ctx.execution_plan > 0 then
        for _, task in ipairs(ctx.execution_plan) do
            if task.file then
                local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, task.file)
                plan_target_files[rel_path] = true
            end
        end
    end
    -- PINNED_TARGETS list for the summary section
    local pinned_targets = {}
    -- LAZY_FILES list for lazy-mode summary
    local lazy_files = {}
    -- Helper: check if file is already in history
    local function is_in_history(path)
        local escaped_path = path:gsub("[%(%)%.%%%+%-%*%?%[%^%$%|]", "%%%1")
        local tag_pattern = "<file_context%s+path=\"" .. escaped_path .. "\""
        for _, msg in ipairs(hist) do
            if msg.content and string.find(msg.content, tag_pattern, 1, true) then
                return true
            end
        end
        return false
    end
    -- Helper: determine if a file should be injected lazily (metadata only)
    local function should_be_lazy(path, content)
        -- Plan targets are NEVER lazy (always full content)
        if plan_target_files[path] then return false end
        -- Files exceeding max_handoff_file_size are always lazy
        if #content > max_handoff_file_size then return true end
        -- If lazy_mode is enabled, non-plan files are lazy
        if lazy_mode then return true end
        return false
    end
    -- Helper: determine status
    local function get_status(path)
        if ctx.pinned_files[path] then return "PINNED"
        elseif ctx.file_states[path] == "RECENTLY_MODIFIED" then return "RECENTLY_MODIFIED" end
        return "READ_ONLY"
    end
    -- Helper: calculate line count
    local function count_lines(content)
        return select(2, content:gsub("\n", "\n"))
    end
    -- Helper: inject file (either full content or lazy metadata)
    local function inject_file(path, content)
        if is_in_history(path) then return end
        local status = get_status(path)
        local line_count = count_lines(content)
        -- Ensure file is pinned in knowledge base
        history.pin_file(ctx, path)
        -- Post-handoff KB eviction: if enabled and file is not a plan target,
        -- remove from knowledge_base to free memory (it's already in agent history)
        local evict = handoff_cfg.evict_from_kb_after_handoff and not plan_target_files[path]
        if should_be_lazy(path, content) then
            -- LAZY MODE: inject only metadata (path, line count, status)
            table.insert(parts, string.format(
                "<handoff_file path=\"%s\" lines=\"%d\" status=\"%s\"/>",
                path, line_count, status
            ))
            table.insert(lazy_files, string.format("%s (%d lines, %s)", path, line_count, status))
        else
            -- FULL MODE: inject complete file content
            table.insert(parts, string.format(
                "<file_context path=\"%s\" status=\"%s\">\n%s\n</file_context>",
                path, status, content
            ))
        end
        -- Evict from KB if configured (file is already in agent's history)
        if evict then
            ctx.knowledge_base[path] = nil
        end
        -- Track pinned targets for summary
        if plan_target_files[path] then
            table.insert(pinned_targets, string.format("%s (%d lines)", path, line_count))
        end
    end
    -- PHASE 1: Inject execution_plan target files FIRST (highest priority)
    for path, _ in pairs(files_to_pass) do
        if plan_target_files[path] and ctx.knowledge_base[path] then
            inject_file(path, ctx.knowledge_base[path])
        end
    end
    -- PHASE 2: Inject remaining files (pinned, requested, knowledge_base)
    for path, _ in pairs(files_to_pass) do
        if not plan_target_files[path] and ctx.knowledge_base[path] then
            inject_file(path, ctx.knowledge_base[path])
        end
    end
    if #parts > 0 then
        -- Build PINNED_TARGETS summary section
        local pinned_targets_section = ""
        if #pinned_targets > 0 then
            pinned_targets_section = "\n<PINNED_TARGETS>\nThe following execution plan target files are pinned and fully loaded:\n"
            for _, pt in ipairs(pinned_targets) do
                pinned_targets_section = pinned_targets_section .. "  - " .. pt .. "\n"
            end
            pinned_targets_section = pinned_targets_section .. "</PINNED_TARGETS>"
        end
        -- Build LAZY_FILES summary section
        local lazy_files_section = ""
        if #lazy_files > 0 then
            lazy_files_section = "\n<LAZY_HANDOFF_FILES>\nThe following files are available but NOT fully loaded. Use read_file to load their content on demand:\n"
            for _, lf in ipairs(lazy_files) do
                lazy_files_section = lazy_files_section .. "  - " .. lf .. "\n"
            end
            lazy_files_section = lazy_files_section .. "</LAZY_HANDOFF_FILES>"
        end
        local block = "\n[HANDOFF CONTEXT - Files from previous stage]\n" .. table.concat(parts, "\n\n") .. pinned_targets_section .. lazy_files_section
        history.add_message(ctx, agent_name, "user", block)
    end
end
return M