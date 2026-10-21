local utils = require("utils")
local CREATE_FILE_MANIFEST = {
    is_mutation = true,
    validate_payload = function(payload)
        if not payload or utils.trim(payload) == "" then
            return false, "create_file payload is empty."
        end
        return true, nil
    end,
    generate_hint = [[
PAYLOAD FORMAT FOR `create_file`:
Output ONLY the full file content. DO NOT include the file path.
The file path is handled automatically by the system.
RULES:
- Output the complete file content from line 1 to the end.
- Do NOT wrap in code fences. Do NOT add explanations.
- Do NOT include the file path in your output.
- Ensure proper syntax for the target language.
]],
    review_checks = [[
TOOL-SPECIFIC REVIEW CHECKS FOR `create_file`:
- [ ] Is the file content syntactically valid for the target language?
- [ ] Does the file content match the stated intent/goal?
- [ ] Are there any obvious bugs or issues in the generated code?
- [ ] If the file is a module, does it have a proper return statement?

- [ ] IF USING PARTIAL VERDICT: List which sections passed and which failed. Only revise the failed sections.
]],
    intent_guideline = "- `create_file`: Use when creating a NEW file. Specify the full file path.",
    multi_stage_docs = [[
This tool is marked [MS] (Multi-Stage). When you see this tag, use the SHORT-FORM command: output ONLY `create_file:file/path` WITHOUT any file content. The system will automatically guide you through Intent → Generate → Review to produce the correct file content. DO NOT include file content in your initial command — the multi-stage pipeline will generate it for you after you specify the goal and file path.
]],
}
local function register(registry)
    registry.register("create_file", "Creates a new file (or overwrites existing). Auto-creates parent directories. Creates .bak backup if file already exists. Multi-stage: use short-form create_file:file/path for MS pipeline.", "||| COMMAND |||\ncreate_file:src/new_module.lua\n\nlocal M = {}\nreturn M\n||| END_COMMAND |||\n\nFORMAT:\n- Line 1 after create_file: = file path.\n- All remaining lines = file content (verbatim, no fences).\n\nBEHAVIOR:\n- Auto-creates parent directories (mkdir -p).\n- If file exists: creates .bak backup (if config.CREATE_BACKUPS ~= false), then overwrites.\n- On success: signal MUTATION_SUCCESS.\n- MS SHORT-FORM: create_file:file/path (no content) -> routes to multi-stage pipeline.", function(args, ctx, agent_name)
        local lines = {}
        for line in args:gmatch("([^\n]*)\n?") do
            table.insert(lines, line)
        end
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
            return { output = "\n[ERROR]: Invalid create_file syntax. No file path provided." }
        end
        local file_content_lines = {}
        for i = path_idx + 1, #lines do
            table.insert(file_content_lines, lines[i])
        end
        local file_content = table.concat(file_content_lines, "\n")
        if utils.trim(file_content) == "" then
            return { output = "\n[ERROR]: Invalid create_file syntax. File content is empty." }
        end
        local path = utils.trim(path_line)
        local rel_path
        local full_path
        if path:match("^/") then
            full_path = path
            rel_path = path
        else
            rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
        end
        -- Create parent directories if needed
        local dir = full_path:match("(.+)/[^/]+$")
        if dir then
            os.execute(string.format("mkdir -p '%s'", dir))
        end
        if ctx.config.CREATE_BACKUPS ~= false and utils.file_exists(full_path) then
            utils.copy_file(full_path, full_path .. ".bak")
        end
        local w_ok, w_err = utils.write_file(full_path, file_content)
        if w_ok then
            ctx:add_file(rel_path, file_content)
            ctx.file_states[rel_path] = "RECENTLY_MODIFIED"
            ctx:squash_last_mutation(agent_name)
            return { output = string.format("\n[SUCCESS]: Created file %s (%d bytes).", rel_path, #file_content), signal = "MUTATION_SUCCESS" }
        else
            return { output = "\n[DISK ERROR]: " .. tostring(w_err) }
        end
    end,
    CREATE_FILE_MANIFEST.multi_stage_docs,
    CREATE_FILE_MANIFEST)
end
return { register = register }