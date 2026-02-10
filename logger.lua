local M = {}
local io = require("io")

local function inspect_impl(root, options)
    options = options or {}
    local depth = options.depth or 3
    local cache = { [root] = "." }
    
    local function _dump(t, space, name, level)
        if level > depth then return space .. tostring(t) .. "..." end
        local temp = {}
        for k,v in pairs(t) do
            local key = tostring(k)
            if type(k) == "string" then key = '"' .. key .. '"' end
            if cache[v] then
                table.insert(temp, "+" .. key .. " {" .. cache[v] .. "}")
            elseif type(v) == "table" then
                local new_key = name .. "." .. key
                cache[v] = new_key
                table.insert(temp, "+" .. key .. _dump(v, space .. (next(t,k) and "|" or " " ) .. string.rep(" ", #key), new_key, level + 1))
            else
                local val_str = tostring(v)
                if type(v) == "string" then val_str = '"' .. val_str .. '"' end
                table.insert(temp, "+" .. key .. " [" .. val_str .. "]")
            end
        end
        return table.concat(temp, "\n" .. space)
    end
    if type(root) ~= "table" then return tostring(root) end
    return "\n" .. _dump(root, "  ", "", 1)
end

function M.info(msg, data)
    local d_str = data and inspect_impl(data) or ""
    print(string.format("\27[32m[INFO]\27[0m %s %s", msg, d_str))
end

function M.warn(msg, data)
    local d_str = data and inspect_impl(data) or ""
    print(string.format("\27[33m[WARN]\27[0m %s %s", msg, d_str))
end

function M.error(msg, data)
    local d_str = data and inspect_impl(data) or ""
    io.stderr:write(string.format("\27[31m[ERROR]\27[0m %s %s\n", msg, d_str))
end

return M
