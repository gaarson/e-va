
local utils = require("utils")

local patcher = require("patcher")


local function register(registry)
    registry.register("patch", "Applies diffs to code. REQUIRES 1-2 lines of unchanged surrounding code (MUC) in the SEARCH block to make the match unique. Do not emit zero-op patches.", "||| COMMAND |||\npatch:src/main.c\n<<<<<<< SEARCH\n unchanged context\n code to remove\n unchanged context\n=======\n unchanged context\n code to add\n unchanged context\n>>>>>>> REPLACE\n||| END_COMMAND |||", function(args, ctx, agent_name)
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
            return { output = "\n[PATCH FAILED]: " .. tostring(changes_or_err) }
        end

    end,
    [[

    MULTI-STAGE GUIDE FOR `patch`:

    1. INTENT PHASE: In PAYLOAD_HINT, specify the EXACT file path, target lines/functions, and WHY the change is needed.
       Example: "Modify src/main.c lines 45-52: replace buffer size check with bounds validation."
    2. GENERATE PHASE: Output ONLY SEARCH/REPLACE diff blocks. SEARCH must have 2-4 lines of unchanged context.
       IMPORTANT: When the file path is already known (provided via command argument), the prompt will state
       "FILE PATH IS ALREADY PROVIDED: <path>". In this case, DO NOT repeat the file path in your output.
       Output ONLY the SEARCH/REPLACE diff blocks. The system will inject the file path automatically.
       If revising, incorporate reviewer corrections - adjust SEARCH context or REPLACE content.
    3. CRITICAL: You MUST have read the target file before patching. Never guess file content.
    ]])
end

return { register = register }
