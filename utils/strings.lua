local M = {}
function M.trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end
function M.normalize_path(root, raw_path)
    if not raw_path then return "" end
    local p = M.trim(raw_path)
    p = p:gsub("^path%s*[:=]%s*", ""):gsub("^file%s*[:=]%s*", ""):gsub("['\"]", "")
    p = M.trim(p)
    p = p:gsub("^%./", "")
    local escaped_root = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    if p:find("^" .. escaped_root) then
        p = p:sub(#root + 2)
    end
    return p:gsub("^/", "")
end
function M.shell_quote(str)
    if not str or str == "" then return "''" end
    return "'" .. str:gsub("'", "'\''") .. "'"
end
return M
