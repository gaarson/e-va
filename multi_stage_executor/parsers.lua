
local utils = require("utils")

local registry = require("tool_registry")

local logger = require("logger")


local M = {}


--- Sanitize LLM-generated payload

local function sanitize_payload(raw)

    if not raw then return "" end

    local s = utils.trim(raw)

    local original_len = #s

    local removed_chars = 0

    s = s:gsub("^%s*```[%w%-]*\n?", "")

    s = s:gsub("\n?```%s*$", "")

    local function strip_balanced_tags(text, open_tag, close_tag)

        local result = text

        local found = true

        while found do

            local start_pos = result:find(open_tag, 1, true)

            if start_pos then

                local end_pos = result:find(close_tag, start_pos + #open_tag, true)

                if end_pos then

                    local removed = result:sub(start_pos, end_pos + #close_tag - 1)

                    removed_chars = removed_chars + #removed

                    result = result:sub(1, start_pos - 1) .. result:sub(end_pos + #close_tag)

                else

                    found = false

                end

            else

                found = false

            end

        end

        return result

    end

    s = strip_balanced_tags(s, "<thinking>", "</thinking>")

    s = strip_balanced_tags(s, "<think>", "<//think>")

    s = strip_balanced_tags(s, "<!--", "-->")

    local preambles = {

        "^here is the payload%s*:?", "^here is the command%s*:?", "^here is the content%s*:?",

        "^command%s*:?", "^payload%s*:?", "^content%s*:?", "^the payload is%s*:?", "^the command is%s*:?",

    }

    for _, pat in ipairs(preambles) do

        s = s:gsub(pat, "", 1)

    end

    s = s:gsub("^%s*|||%s*COMMAND%s*|||%s*\n?", "")

    s = s:gsub("\n?|||%s*END_COMMAND%s*|||%s*$", "")

    local final_s = utils.trim(s)

    if removed_chars > 100 then

        logger.info(string.format("[SANITIZE] Removed %d chars of thinking/tags from payload (%.1f%% of original)",

            removed_chars, (removed_chars / original_len) * 100))

    end

    return final_s

end


--- Safe template renderer

local function render(template, vars)

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

    if tool_name == "delegate_plan" then

        local json = require("JSON")

        local ok, data = pcall(json.decode, payload)

        if not ok then

            return false, "delegate_plan payload is not valid JSON: " .. tostring(data)

        end

        if not data.plan or type(data.plan) ~= "table" then

            return false, "delegate_plan payload missing 'plan' array."

        end

        if not data.memo or utils.trim(data.memo) == "" then

            return false, "delegate_plan payload missing or empty 'memo' field."

        end

    elseif tool_name == "patch" then

        if not payload:find("<<<<<<< SEARCH") then

            return false, tool_name .. " payload must contain at least one SEARCH/REPLACE block."

        end

        if not payload:find(">>>>>>> REPLACE") then

            return false, tool_name .. " payload has SEARCH block but no closing REPLACE marker."

        end

    elseif tool_name == "create_file" then

        local first_line = payload:match("^[^\r\n]+")

        if not first_line or utils.trim(first_line) == "" then

            return false, "create_file payload must start with a file path."

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

    if #trimmed <= 200 then return trimmed end

    local sub = trimmed:sub(1, 200)

    local last_period = sub:find("%. ", 180) or sub:find("%.$", 180)

    if last_period then

        return sub:sub(1, last_period) .. "..."

    end

    return sub:sub(1, 197) .. "..."

end


--- Estimate task complexity
local function estimate_complexity(tool_name, payload_hint, file_path)
    -- (b) delegate_plan and shell are always complex
    if tool_name == "delegate_plan" or tool_name == "shell" then
        return "complex"
    end
    local hint_lower = (payload_hint or ""):lower()
    -- (c) payload_hint contains complexity keywords
    local complex_keywords = { "multiple", "refactor", "rewrite", "large", "comprehensive", "extensive", "all", "entire" }
    for _, kw in ipairs(complex_keywords) do
        if hint_lower:match(kw) then
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
    -- (a) if file_path exists in knowledge_base, check file size (>500 lines = complex)
    if file_path then
        local kb = require("context_flow").get_global_knowledge_base()
        if kb then
            local content = kb[file_path]
            if content then
                local line_count = select(2, content:gsub("\n", "\n"))
                if line_count > 500 then
                    return "complex"
                end
            end
        end
    end
    local is_small_payload = hint_lower:match("small") or hint_lower:match("simple") or hint_lower:match("single") or
        hint_lower:match("short") or hint_lower:match("<500") or hint_lower:match("<1000")
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
