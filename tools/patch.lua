local utils = require("utils")
local patcher = require("patcher")

local PATCH_MANIFEST = {
    is_mutation = true,
    validate_payload = function(payload)
        if not payload or utils.trim(payload) == "" then
            return false, "patch payload is empty."
        end
        if not payload:find("<<<<<<< SEARCH") then
            return false, "patch payload must contain at least one SEARCH/REPLACE block."
        end
        if not payload:find(">>>>>>> REPLACE") then
            return false, "patch payload has SEARCH block but no closing REPLACE marker."
        end
        return true, nil
    end,

    generate_hint = [[
PAYLOAD FORMAT FOR `patch`:
Output ONLY SEARCH/REPLACE diff blocks. DO NOT include the file path.
The file path is handled automatically by the system.

<<<<<<< SEARCH
<exact lines from the file, 2-4 lines of UNCHANGED context>
<lines to replace>
<more unchanged context>
=======
<exact same unchanged context lines>
<new replacement lines>
<same unchanged context lines>
>>>>>>> REPLACE

RULES:
- SEARCH block MUST match the actual file content EXACTLY (character-for-character).
- Include 2-4 lines of unchanged context around the change to make the match unique.
- The unchanged context lines must appear IDENTICALLY in both SEARCH and REPLACE blocks.
- Do NOT wrap in code fences. Do NOT add explanations.
- Do NOT include the file path in your output.
- If multiple changes in the same file, output multiple SEARCH/REPLACE blocks sequentially.
]],
    review_checks = [[
TOOL-SPECIFIC REVIEW CHECKS FOR `patch`:
- [ ] Does every SEARCH block contain 2-4 lines of unchanged context?
- [ ] Would the SEARCH blocks match the actual file content exactly?
- [ ] Are there zero-op patches (SEARCH == REPLACE)?
- [ ] If multiple patches, is the application order correct?
- [ ] Did the execution result confirm successful patching (no [PATCH FAILED])?
- [ ] Are the changed lines syntactically valid for the target language?
- [ ] If revision was requested, were the reviewer's corrections applied correctly?

- [ ] IF --- UNIFIED DIFF --- IS PRESENT IN THE EXECUTION RESULT:
     Verify the diff accurately represents the changes made.
     Confirm that removed lines (-) and added lines (+) match the intended modification.
- [ ] IF USING PARTIAL VERDICT: List which specific SEARCH/REPLACE blocks passed and which failed. Only revise the failed blocks.
]],
    intent_guideline = "- `patch`: Use when modifying an existing file. You MUST know the exact file content. Include sufficient SEARCH context.",
    multi_stage_docs = [[
This tool is marked [MS] (Multi-Stage). When you see this tag, use the SHORT-FORM command: output ONLY `patch:file/path` WITHOUT any SEARCH/REPLACE blocks. The system will automatically guide you through Intent → Generate → Review to produce the correct payload. DO NOT include SEARCH/REPLACE blocks in your initial command — the multi-stage pipeline will generate them for you after you specify the goal and file path.
]],
}

local function register(registry)
    registry.register("patch", "Applies SEARCH/REPLACE diffs to existing files. Requires exact character-for-character match. Creates .bak backup before writing. Multi-stage: use short-form patch:file/path for MS pipeline, or full SEARCH/REPLACE blocks for direct execution.", "||| COMMAND |||\npatch:src/main.c\n<<<<<<< SEARCH\n unchanged context line 1\n code to remove\n unchanged context line 2\n=======\n unchanged context line 1\n new replacement code\n unchanged context line 2\n>>>>>>> REPLACE\n||| END_COMMAND |||\n\nFORMAT:\n- Line 1 after patch: = file path (relative or absolute).\n- Remaining lines = patch body with SEARCH/REPLACE blocks.\n- Multiple blocks allowed (applied sequentially, top-to-bottom).\n\nRULES:\n- SEARCH must match file content EXACTLY (tabs, spaces, newlines).\n- Include 2-4 unchanged context lines for uniqueness.\n- Context lines must be IDENTICAL in SEARCH and REPLACE.\n- No code fences, no explanations, no file path inside blocks.\n\nBEHAVIOR:\n- Creates .bak backup (if config.CREATE_BACKUPS ~= false).\n- On success: returns unified diff + signal MUTATION_SUCCESS.\n- On failure: returns debug info (SEARCH preview, file snippet, contextual hint).\n- MS SHORT-FORM: patch:file/path (no blocks) routes to multi-stage pipeline.", function(args, ctx, agent_name)
        -- LINE-BASED PATH EXTRACTION (Step 4 fix):
        -- Split args into lines; first non-empty line is the path, rest is the patch body.

        local lines = {}
        for line in args:gmatch("([^\n]*)\n?") do
            table.insert(lines, line)
        end

        -- Find first non-empty line as path
        local path_line = nil
        local path_idx = nil
        for i, l in ipairs(lines) do
            if l:match("%S") then
                path_line = l
                path_idx = i
                break
            end
        end

        if not path_line then
            return { output = "\n[ERROR]: Invalid patch syntax. No file path provided. Use ||| COMMAND |||\npatch:file\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n\n||| END_COMMAND |||" }
        end

        -- Everything after the path line is the patch body

        local patch_body_lines = {}

        for i = path_idx + 1, #lines do
            table.insert(patch_body_lines, lines[i])
        end

        local patch_body = table.concat(patch_body_lines, "\n")

        if utils.trim(patch_body) == "" then
            return { output = "\n[ERROR]: Invalid patch syntax. Patch body is empty. Use ||| COMMAND |||\npatch:file\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n\n||| END_COMMAND |||" }
        end

        local path = utils.trim(path_line)

        -- Handle absolute vs relative paths
        local rel_path
        local full_path

        if path:match("^/") then
            -- Absolute path: use as-is for full_path, derive rel_path for KB key
            full_path = path
            rel_path = path
        else
            -- Relative path: normalize relative to PROJECT_ROOT
            rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
        end

        if not ctx.knowledge_base[rel_path] then
            local content = utils.read_file_range(full_path)
            if content then ctx:add_file(rel_path, content)
            else return { output = "\n[ERROR] File not found on disk: " .. rel_path } end
        end

        local ok, new_content, changes_or_err, diff_str = patcher.apply_patch(ctx.knowledge_base[rel_path], patch_body)
        if ok then
            if ctx.config.CREATE_BACKUPS ~= false then
                utils.copy_file(full_path, full_path .. ".bak")
            end
            local w_ok, w_err = utils.write_file(full_path, new_content)
            if w_ok then
                ctx:add_file(rel_path, new_content)
                ctx.file_states[rel_path] = "RECENTLY_MODIFIED"
                ctx:squash_last_mutation(agent_name)
                local diff_output = diff_str and diff_str ~= "" and ("\n\n--- UNIFIED DIFF ---\n" .. diff_str) or ""
                return { output = string.format("\n[SUCCESS]: Applied %d patch block(s) to %s.%s", changes_or_err, rel_path, diff_output), signal = "MUTATION_SUCCESS" }
              else
                return { output = "\n[DISK ERROR]: " .. tostring(w_err) }
            end
        else
            -- Build structured error detail for recovery
            local file_content = ctx.knowledge_base[rel_path] or ""
            local error_detail = "\n[PATCH FAILED]: " .. tostring(changes_or_err)
            -- Extract SEARCH block from patch body for debug info
            local search_block = patch_body:match("<<<<<<< SEARCH\n(.-)\n=======")
            local search_preview = ""
            if search_block then
                local search_lines = {}
                for line in search_block:gmatch("[^\r\n]+") do
                    if #search_lines < 3 then
                        table.insert(search_lines, line)
                    end
                end
                search_preview = "\n   Your SEARCH block started with:\n   " .. table.concat(search_lines, "\n   ")
            end
            -- Show actual file content snippet
            local file_snippet = ""
            if #file_content > 0 then
                local file_lines = {}
                for line in file_content:gmatch("[^\r\n]+") do
                    if #file_lines < 10 then
                        table.insert(file_lines, line)
                    end
                end
                file_snippet = "\n\n   Actual file content (first 10 lines):\n   " .. table.concat(file_lines, "\n   ")
            end
            -- Contextual hint
            local hint = ""
            local err_str = tostring(changes_or_err)
            if err_str:match("[Ii][Nn][Oo] [Mm][Aa][Tt][Cc][Hh]") or err_str:match("[Nn]o matching") then
                hint = "\n\n   HINT: SEARCH block did not match file content. Common causes:\n" ..
                       "   - Whitespace mismatch (tabs vs spaces)\n" ..
                       "   - File was modified by a previous patch in this command\n" ..
                       "   - Not enough unchanged context lines in SEARCH block\n" ..
                       "   ACTION: Re-read the file with read_file before retrying."
            elseif err_str:match("[Aa]mbiguous") then
                hint = "\n\n   HINT: SEARCH block matched multiple locations. Add more unchanged context lines (2-4) to make the match unique."
            else
                hint = "\n\n   HINT: Re-read the file with read_file to see current content, then adjust your SEARCH block."
            end
            error_detail = error_detail .. search_preview .. file_snippet .. hint .. "\n   --- END DEBUG ---"
            -- Track patch failure in recent tool outputs for context
            ctx:add_tool_output("patch", string.format("PATCH FAILED on %s: %s", rel_path, tostring(changes_or_err)))
            return { output = error_detail, signal = "FAILURE" }
        end

    end,
    PATCH_MANIFEST.multi_stage_docs,
    PATCH_MANIFEST)
end

return { register = register }