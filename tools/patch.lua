local utils = require("utils")
local patcher = require("patcher")

local function register(registry)
    registry.register("patch", "Applies diffs to code. REQUIRES 1-2 lines of unchanged surrounding code (MUC) in the SEARCH block to make the match unique. Do not emit zero-op patches.", "<cmd>patch:src/main.c\n<<<<<<< SEARCH\n unchanged context\n code to remove\n unchanged context\n=======\n unchanged context\n code to add\n unchanged context\n>>>>>>> REPLACE\n</cmd>", function(args, ctx, agent_name)
        local path, patch_body = args:match("^([^%s\n]+)%s*\n(.*)")
        if not path or not patch_body then
            return { output = "\n[ERROR]: Invalid patch syntax. Use <cmd>patch:file\n<<<<<<< SEARCH\n...\n=======\n...\n>>>>>>> REPLACE\n</cmd>" }
        end

        local rel_path = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
        local full_path = ctx.config.PROJECT_ROOT .. "/" .. rel_path

        if not ctx.knowledge_base[rel_path] then
            local content = utils.read_file_range(full_path)
            if content then ctx:add_file(rel_path, content)
            else return { output = "\n[ERROR] File not found on disk: " .. rel_path } end
        end

        local ok, new_content, changes, err_msg = patcher.apply_patch(ctx.knowledge_base[rel_path], patch_body)

        if ok then
            if ctx.config.CREATE_BACKUPS ~= false then
                utils.copy_file(full_path, full_path .. ".bak")
            end
            local w_ok, w_err = utils.write_file(full_path, new_content)
            if w_ok then
                ctx:add_file(rel_path, new_content)
                ctx.file_states[rel_path] = "RECENTLY_MODIFIED"
                ctx:squash_last_mutation(agent_name)
                return { output = string.format("\n[SUCCESS]: Applied %d patch block(s) to %s.", changes, rel_path), signal = "MUTATION_SUCCESS" }
              else
                return { output = "\n[DISK ERROR]: " .. tostring(w_err) }
            end
        else
            return { output = "\n[PATCH FAILED]: " .. tostring(err_msg) }
        end
    end)
end

return { register = register }
