-- context/handoff.lua


-- Handoff/stage transition extracted from context_flow.lua.

-- All functions take ctx (the context_flow instance) as the first argument.


local M = {}


local utils = require("utils")

local history = require("context.history")

local builder = require("context.builder")


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

    -- Helper: determine status and inject file content

    local function inject_file(path, content)

        if is_in_history(path) then return end

        local status = "READ_ONLY"

        if ctx.pinned_files[path] then status = "PINNED"

        elseif ctx.file_states[path] == "RECENTLY_MODIFIED" then status = "RECENTLY_MODIFIED" end

        -- Ensure file is pinned

        history.pin_file(ctx, path)

        -- Calculate line count for metadata

        local line_count = select(2, content:gsub("\n", "\n"))

        -- For plan target files: ALWAYS show full content (no truncation)

        -- For non-plan files: also show full content (handoff files should be complete)

        local display_content = content

        table.insert(parts, string.format(

            "<file_context path=\"%s\" status=\"%s\">\n%s\n</file_context>",

            path, status, display_content

        ))

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

        local block = "\n[HANDOFF CONTEXT - Files from previous stage]\n" .. table.concat(parts, "\n\n") .. pinned_targets_section

        history.add_message(ctx, agent_name, "user", block)

    end

end


return M