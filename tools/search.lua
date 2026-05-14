local utils = require("utils")

local function register(registry)
    registry.register("search", "Fast RipGrep search", "<cmd>search:function_name</cmd>", function(args, ctx, agent_name)
        local query = utils.trim(args)
        if query == "" then return { output = "\n[ERROR]: Empty search query." } end
        if ctx:has_searched(query) then return { output = "\n[SYSTEM]: Skipped duplicate search. Check History." } end

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
    end)
end

return { register = register }