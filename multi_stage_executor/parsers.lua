local utils = require("utils")
local registry = require("tool_registry")
local logger = require("logger")
local M = {}
--- Sanitize LLM-generated payload
local function sanitize_payload(raw)
    if not raw then return "" end
    local s = utils.trim(raw)
    local original_len = #s
    -- Strip markdown fences
    s = s:gsub("^%s*```[%w%-]*\n?", "")
    s = s:gsub("\n?```%s*$", "")
    -- Strip known preamble patterns (case-insensitive via character classes)
    -- NOTE: Lua patterns do NOT support | alternation, so we use separate gsub calls
    s = s:gsub("^%s*[Hh][Ee][Rr][Ee]%s+[Ii][Ss]%s+[Tt][Hh][Ee]%s+payload%s*:%s*", "", 1)
    s = s:gsub("^%s*[Hh][Ee][Rr][Ee]%s+[Ii][Ss]%s+[Tt][Hh][Ee]%s+command%s*:%s*", "", 1)
    s = s:gsub("^%s*[Hh][Ee][Rr][Ee]%s+[Ii][Ss]%s+[Tt][Hh][Ee]%s+content%s*:%s*", "", 1)
    s = s:gsub("^%s*[Cc][Oo][Mm][Mm][Aa][Nn][Dd]%s*:%s*", "", 1)
    s = s:gsub("^%s*[Pp][Aa][Yy][Ll][Oo][Aa][Dd]%s*:%s*", "", 1)
    s = s:gsub("^%s*[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%s*:%s*", "", 1)
    s = s:gsub("^%s*[Tt][Hh][Ee]%s+[Pp][Aa][Yy][Ll][Oo][Aa][Dd]%s+[Ii][Ss]%s*:%s*", "", 1)
    s = s:gsub("^%s*[Tt][Hh][Ee]%s+[Cc][Oo][Mm][Mm][Aa][Nn][Dd]%s+[Ii][Ss]%s*:%s*", "", 1)
    -- Strip command markers
    s = s:gsub("^%s*|||%s*COMMAND%s*|||%s*\n?", "")
    s = s:gsub("\n?|||%s*END_COMMAND%s*|||%s*$", "")
    local final_s = utils.trim(s)
    local removed_chars = original_len - #final_s
    if removed_chars > 100 then
        logger.info(string.format("[SANITIZE] Removed %d chars of thinking/tags from payload (%.1f%% of original)",
            removed_chars, (removed_chars / original_len) * 100))
    end
    return final_s
end
--- Safe template renderer
local function render(template, vars)
    vars = vars or {}
    return (template:gsub("{([%w_]+)}", function(key)
        local v = vars[key]
        if v == nil then return "{" .. key .. "}" end
        return tostring(v)
    end))
end
--- Validate payload content based on tool type
local function validate_payload(tool_name, payload)
    if not payload or utils.trim(payload) == "" then
        return false, "Payload is empty."
    end
    -- Try manifest-based validation first
    local tool = registry.tools[tool_name]
    if tool and tool.manifest and tool.manifest.validate_payload then
        local ok, err = tool.manifest.validate_payload(payload)
        if not ok then
            return false, err or ("Validation failed for tool '" .. tool_name .. "'.")
        end
    end
    return true, nil
end
--- Extract field from block
local function extract_field(block, name)
    if not block or not name then return "" end
    local target_upper = name:upper()
    local lines = {}
    for line in block:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    local results = {}
    local current_key = nil
    local current_value = {}
    for i = 1, #lines do
        local line = lines[i]
        local field_name, field_value = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*:%s*(.*)")
        if field_name then
            if current_key then
                results[current_key:upper()] = table.concat(current_value, "\n")
            end
            current_key = field_name:upper()
            current_value = { field_value }
        else
            if current_key then
                table.insert(current_value, line)
            end
        end
    end
    if current_key then
        results[current_key:upper()] = table.concat(current_value, "\n")
    end
    local val = results[target_upper]
    if val == nil then return "" end
    return utils.trim(val)
end
--- Summarize a correction
local function summarize_correction(correction)
    local trimmed = utils.trim(correction)
    -- Fix #4: Increased truncation limit from 200 to 500 chars
    if #trimmed <= 500 then return trimmed end
    local sub = trimmed:sub(1, 500)
    -- Find last period followed by space, or period near end
    local last_period = sub:find("%. ", 480)
    if not last_period then
        -- Try to find any period in the last 20 chars
        for i = 480, #sub do
            if sub:sub(i, i) == "." then
                last_period = i
                break
            end
        end
    end
    if last_period then
        return sub:sub(1, last_period) .. "..."
    end
    return sub:sub(1, 497) .. "..."
end
--- Estimate task complexity
local function estimate_complexity(tool_name, payload_hint, file_path)
    -- Try manifest-based complexity estimation first
    local tool = registry.tools[tool_name]
    if tool and tool.manifest and tool.manifest.estimate_complexity then
        return tool.manifest.estimate_complexity(tool_name, payload_hint, file_path)
    end
    -- Fallback heuristic logic
    -- (b) delegate_plan and shell are always complex
    if tool_name == "delegate_plan" or tool_name == "shell" then
        return "complex"
    end
    local hint_lower = (payload_hint or ""):lower()
    -- (c) payload_hint contains complexity keywords
    local complex_keywords = { "multiple", "refactor", "rewrite", "large", "comprehensive", "extensive", "all", "entire" }
    for _, kw in ipairs(complex_keywords) do
        if hint_lower:find("%f[%a]" .. kw .. "%f[^%a]") then
            return "complex"
        end
    end
    local simple_extensions = { ".md", ".txt", ".json", ".cfg", ".yaml", ".toml", ".ini", ".env", ".lock", ".gitignore" }
    local is_simple_ext = false
    if file_path then
        for _, ext in ipairs(simple_extensions) do
            if file_path:match(ext .. "$") then
                is_simple_ext = true
                break
            end
        end
    end
    -- Use string.find instead of pattern.match for literal substring search
    local is_small_payload = hint_lower:find("small") or hint_lower:find("simple") or hint_lower:find("single") or
        hint_lower:find("short") or hint_lower:find("<500") or hint_lower:find("<1000")
    if is_simple_ext and is_small_payload then
        return "simple"
    end
    if tool_name == "create_file" and is_simple_ext then
        return "simple"
    end
    return "complex"
end
-- Export functions
M.sanitize_payload = sanitize_payload
M.render = render
M.validate_payload = validate_payload
M.extract_field = extract_field
M.summarize_correction = summarize_correction
M.estimate_complexity = estimate_complexity
return M
