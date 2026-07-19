local io = require("io")
local strings = require("utils.strings")
local file_io = require("utils.file_io")
local M = {}
function M.list_files_recursive(root_path)
    local safe_root = strings.shell_quote(root_path)
    local cmd = string.format("rg --files --hidden --glob '!.git/' --glob '!.e-va-conf/' --glob '!lua_modules/' --glob '!.luacov*' --glob '!*.report.out' --glob '!*.stats.out' --color never %s 2>/dev/null", safe_root)
    local p = io.popen(cmd)
    if not p then return "Error listing files" end
    local out = p:read("*a")
    p:close()
    local files = {}
    for line in out:gmatch("[^\r\n]+") do
        local rel = strings.normalize_path(root_path, line)
        if rel ~= "" then
            local full_path = root_path .. "/" .. rel
            local lines_count = file_io.count_lines_fast(full_path)
            table.insert(files, string.format("%s (%s lines)", rel, tostring(lines_count)))
        end
    end
    if #files == 0 then return "(No files found)" end
    table.sort(files)
    return table.concat(files, "\n")
end
function M.explore_directory(root_path, target_subpath, max_depth)
    local target = target_subpath and target_subpath ~= "" and target_subpath or "."
    local full_target = strings.normalize_path(root_path, target)
    local absolute_target = root_path .. "/" .. full_target
    local safe_target = strings.shell_quote(absolute_target)
    local depth = tonumber(max_depth) or 1
    local cmd = string.format(
        "find %s -maxdepth %d -not -path '*/\\.git*' -not -path '*/node_modules*' -not -path '*/build*' -not -path '*/\\.e-va-conf*' -not -path '*/lua_modules*' -not -path '*/.luacov*' -not -path '*/*.report.out' -not -path '*/*.stats.out' 2>/dev/null | sort",
        safe_target, depth
    )
    local p = io.popen(cmd)
    if not p then return "[ERROR] Failed to execute directory scan" end
    local out = p:read("*a")
    p:close()
    local files = {}
    local max_files = 200
    local count = 0
    for line in out:gmatch("[^\r\n]+") do
        if count >= max_files then break end
        local rel = strings.normalize_path(root_path, line)
        if rel ~= "" and rel ~= full_target then
            local full_path = root_path .. "/" .. rel
            local safe_full_path = strings.shell_quote(full_path)
            local is_dir = os.execute(string.format("test -d %s", safe_full_path)) == 0
            if is_dir then
                table.insert(files, "  " .. rel .. "/")
            else
                local lines_count = file_io.count_lines_fast(full_path)
                table.insert(files, string.format("  %s (%s lines)", rel, tostring(lines_count)))
            end
            count = count + 1
        end
    end
    if #files == 0 then return "(Directory is empty or access denied)" end
    return string.format("Directory: /%s\n%s", full_target, table.concat(files, "\n"))
end
return M
