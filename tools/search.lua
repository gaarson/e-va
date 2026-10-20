local utils = require("utils")
local SEARCH_MANIFEST = {
    is_mutation = false,
    validate_payload = function(payload)
        return true, nil
    end,
    enrich_result = function(output)
        return output
    end,
    generate_hint = "",
    review_checks = "",
    intent_guideline = "search: Fast RipGrep text search across codebase.",
}
local function register(registry)
    registry.register("search", "Fast case-insensitive fixed-string search across codebase (RipGrep). NOT regex. Results truncated at 4000 chars. Repeated identical queries return cached results.", "||| COMMAND |||\nsearch:function_name\n||| END_COMMAND |||\n\nArgs: <query_string>\n- Uses: rg -n -i -C 1 --fixed-strings (case-insensitive, 1 line context, NO regex)\n- Excludes: .git/, .e-va-conf/\n- Output truncated at 4000 characters.\n- Dedup: identical query in same session returns cached result without re-running rg.\n- For regex search, use shell:rg -P 'pattern' <path>", function(args, ctx, agent_name)
        local query = utils.trim(args)
        if query == "" then return { output = "\n[ERROR]: Empty search query." } end
        -- DEDUP: If this exact query was already executed in this session, return cached result.
        -- This prevents redundant rg calls when the model retries the same search.
        if ctx:has_searched(query) then return { output = "\n[SEARCH RESULTS for '"..query.."']:\n" .. ctx.search_history[query] } end
        local safe_query = utils.shell_quote(query)
        local safe_root = utils.shell_quote(ctx.config.PROJECT_ROOT)
        local cmd = string.format("rg -n -i -C 1 --color never --fixed-strings --glob '!.git/' --glob '!.e-va-conf/' %s %s 2>&1 | head -c 4000", safe_query, safe_root)
        local f = io.popen(cmd)
        local res = f:read("*a") or ""
        f:close()
        if #res == 0 then res = "(No matches found)"
        elseif #res >= 4000 then res = res .. "\n...(Truncated)..." end
        ctx:add_search_result(query, res)
        return { output = "\n[SEARCH RESULTS for '"..query.."']:\n" .. res }
    end,
    nil,
    SEARCH_MANIFEST)
end
return { register = register }