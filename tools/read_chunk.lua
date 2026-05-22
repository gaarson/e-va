local utils = require("utils")

local function register(registry)
    registry.register("read_chunk", "Reads specific lines from a file", "<cmd>read_chunk:src/main.c:10-25</cmd>", function(args, ctx, agent_name)
        local path, start_l, end_l = args:match("^(.-):(%d+)%-(%d+)$")
        if not path then path, start_l, end_l = args:match("^path:(.-):(%d+)%-(%d+)$") end

        if path then
            local rel = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            local full = ctx.config.PROJECT_ROOT .. "/" .. rel
            local s_idx, e_idx = tonumber(start_l), tonumber(end_l)

            if ctx.knowledge_base[rel] then
                ctx:touch_file(rel)

                local lines = utils.read_lines_raw(ctx.knowledge_base[rel])
                local total_lines = #lines

                if s_idx < 1 then s_idx = 1 end
                if e_idx > total_lines then e_idx = total_lines end

                if s_idx > total_lines then
                    return { output = string.format("\n[ERROR] Start line %d is beyond EOF (Total lines: %d).", s_idx, total_lines) }
                end

                local chunk_lines = {}
                for i = s_idx, e_idx do
                    table.insert(chunk_lines, string.format("%4d | %s", i, lines[i]))
                end

                local content = table.concat(chunk_lines, "\n")
                return { 
                    output = string.format("\n[SYSTEM OPTIMIZATION: Zero-I/O Memory Read] Chunk of '%s' (Lines %d-%d):\n```\n%s\n```", rel, s_idx, e_idx, content) 
                }
            end

            local content, total = utils.read_file_numbered(full, s_idx, e_idx)
            if content then
                return { output = string.format("\n[SYSTEM] Chunk of '%s' (Lines %d-%d):\n```\n%s\n```", rel, s_idx, e_idx, content) }
            else
                return { output = "[ERROR] Could not read chunk: " .. rel }
            end
        else
            return { output = "[ERROR] Usage: read_chunk:filename:start-end" }
        end
    end)
end

return { register = register }
