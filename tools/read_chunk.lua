local utils = require("utils")
local READ_CHUNK_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output_str)
        return output_str
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "read_chunk: Reads specific line ranges from a file. Use when you only need a portion of a large file.",
}
local function register(registry)
    registry.register("read_chunk", "Reads specific lines from a file", "||| COMMAND |||\nread_chunk:src/main.c:10-25\n||| END_COMMAND |||", function(args, ctx, agent_name)
        local path, start_l, end_l = args:match("^(.-):(%d+)%-(%d+)$")
        if not path then path, start_l, end_l = args:match("^path:(.-):(%d+)%-(%d+)$") end
        if path then
            local rel = utils.normalize_path(ctx.config.PROJECT_ROOT, path)
            local full = ctx.config.PROJECT_ROOT .. "/" .. rel
            local s_idx, e_idx = tonumber(start_l), tonumber(end_l)
            if ctx.knowledge_base[rel] then
                ctx:touch_file(rel)
                ctx:track_requested_file(rel)
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
            -- FIX: Read FULL file to avoid polluting knowledge_base with partial content
            local full_content, ferr = utils.read_file_range(full)
            if full_content then
                ctx:add_file(rel, full_content)
                ctx:track_requested_file(rel)
                local all_lines = utils.read_lines_raw(full_content)
                local chunk_lines = {}
                for i = s_idx, math.min(e_idx, #all_lines) do
                    table.insert(chunk_lines, string.format("%4d | %s", i, all_lines[i]))
                end
                local chunk_display = table.concat(chunk_lines, "\n")
                return { output = string.format("\n[SYSTEM] Chunk of '%s' (Lines %d-%d):\n```\n%s\n```", rel, s_idx, e_idx, chunk_display) }
            else
                return { output = "[ERROR] Could not read chunk: " .. rel }
            end
        else
            return { output = "[ERROR] Usage: read_chunk:filename:start-end" }
        end
    end, nil, READ_CHUNK_MANIFEST)
end
return { register = register }
