local utils = require("utils")
local patcher = require("patcher")

local function register(registry)
    registry.register("batch_patch", "Applies patches to multiple files in a single command.", "||| COMMAND |||\nbatch_patch:file1\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n---FILE---\nfile2\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local blocks = {}
        local current_block = ""
        local current_file = nil
        
        for line in args:gmatch("[^\r\n]+") do
            if line:match("^---FILE---$") then
                if current_file and current_block ~= "" then
                    table.insert(blocks, { file = current_file, patch = current_block })
                end
                current_block = ""
                current_file = nil
            elseif not current_file then
                current_file = utils.trim(line)
            else
                current_block = current_block .. line .. "\n"
            end
        end
        
        if current_file and current_block ~= "" then
            table.insert(blocks, { file = current_file, patch = current_block })
        end
        
        if #blocks == 0 then
            return { output = "\n[ERROR]: No valid patch blocks found. Use ||| COMMAND |||\nbatch_patch:file1\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n---FILE---\nfile2\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n||| END_COMMAND |||" }
        end
        
        local results = {}
        local successes = 0
        local failures = 0
        
        for _, block in ipairs(blocks) do
            local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, block.file)
            local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path
            
            if not ctx.knowledge_base[rel_path] then
                local content = utils.read_file_range(full_path)
                if content then
                    ctx:add_file(rel_path, content)
                else
                    table.insert(results, string.format("- %s: ERROR - File not found", rel_path))
                    failures = failures + 1
                end
            else
                local ok, new_content, changes, err_msg = patcher.apply_patch(ctx.knowledge_base[rel_path], block.patch)
                if ok then
                    if ctx.config.CREATE_BACKUPS ~= false then
                        utils.copy_file(full_path, full_path .. ".bak")
                    end
                    local w_ok, w_err = utils.write_file(full_path, new_content)
                    if w_ok then
                        ctx:add_file(rel_path, new_content)
                        ctx.file_states[rel_path] = "RECENTLY_MODIFIED"
                        table.insert(results, string.format("- %s: SUCCESS (%d changes)", rel_path, changes))
                        successes = successes + 1
                    else
                        table.insert(results, string.format("- %s: ERROR - %s", rel_path, tostring(w_err)))
                        failures = failures + 1
                    end
                else
                    table.insert(results, string.format("- %s: ERROR - %s", rel_path, tostring(err_msg)))
                    failures = failures + 1
                end
            end
        end
        
        local output = string.format("\n[SYSTEM]: Batch patch complete. Successes: %d, Failures: %d\n%s", successes, failures, table.concat(results, "\n"))
        return { output = output, signal = successes > 0 and "MUTATION_SUCCESS" or nil }
    end,
    [[
    MULTI-STAGE GUIDE FOR `batch_patch`:
    1. INTENT PHASE: In PAYLOAD_HINT, list ALL files to modify and the nature of each change.
       Example: "Patch 3 files: src/a.c (fix leak), src/b.c (add null check), src/c.h (update struct)."
    2. GENERATE PHASE: Output ONLY batch format with ---FILE--- separators. Each file gets SEARCH/REPLACE blocks.
       If revising, fix only failed patches - keep successful ones intact.
    3. CRITICAL: Every SEARCH block needs 2-4 lines of unchanged context. Order matters for dependencies.
    
    ]]
)
end
return { register = register }
