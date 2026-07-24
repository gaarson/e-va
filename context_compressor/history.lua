local helpers = require("context_compressor.helpers")
local thinking = require("context_compressor.thinking")
local tool_output = require("context_compressor.tool_output")
local M = {}
function M.compress_history_window(history, config)
    config = config or helpers.DEFAULT_CONFIG
    if not history or #history == 0 then return history, 0 end
    local total = #history
    local zone1_end = total
    local zone2_end = total - config.zone1_size
    local zone3_end = zone2_end - config.zone2_size
    if zone3_end < 1 then zone3_end = 1 end
    if zone2_end < 1 then zone2_end = 1 end
    local compressed_count = 0
    local tokens_saved = 0
    for i = 1, zone3_end - 1 do
        local msg = history[i]
        if msg and msg.content then
            local original_len = #msg.content
            if helpers._is_task_critical(msg) then
                msg.content = thinking.compress_assistant_thinking(msg.content, config)
                if msg.content:match("^%[") then
                    msg.content = tool_output.compress_tool_output(msg.content, config)
                end
            else
                msg.content = helpers._summarize_message(msg, config)
            end
            tokens_saved = tokens_saved + (original_len - #msg.content)
            compressed_count = compressed_count + 1
        end
    end
    for i = zone3_end, zone2_end - 1 do
        local msg = history[i]
        if msg and msg.content then
            local original_len = #msg.content
            msg.content = thinking.compress_assistant_thinking(msg.content, config)
            if msg.content:match("^%[") then
                msg.content = tool_output.compress_tool_output(msg.content, config)
            end
            tokens_saved = tokens_saved + (original_len - #msg.content)
            compressed_count = compressed_count + 1
        end
    end
    return history, compressed_count, tokens_saved
end
function M.calculate_compression_ratio(original, compressed)
    if not original or #original == 0 then return 1.0 end
    if not compressed or #compressed == 0 then return 0.0 end
    return #compressed / #original
end
function M.is_compressible(msg, config)
    config = config or helpers.DEFAULT_CONFIG
    if not msg or not msg.content then return false end
    local content = msg.content
    local len = #content
    if len < 200 then return false end
    if content:match("||| COMMAND |||") then return false end
    if msg.role == "system" and len < 500 then return false end
    if config.compress_thinking_blocks and (content:match("<thinking>") or content:match("<think>")) then return true end
    if content:match("^%[SHELL") or content:match("^%[SEARCH") or content:match("^%[OUTPUT") or content:match("^%[RESULT") then
        if len > config.max_tool_output_bytes then return true end
    end
    if len > 5000 then return true end
    return false
end
function M.compress_message(msg, config)
    config = config or helpers.DEFAULT_CONFIG
    if not msg or not msg.content then return msg end
    local original_content = msg.content
    msg.content = thinking.compress_assistant_thinking(msg.content, config)
    if msg.content:match("^%[SHELL") or msg.content:match("^%[SEARCH") or
       msg.content:match("^%[OUTPUT") or msg.content:match("^%[RESULT") or
       msg.content:match("^%[FILE") then
        msg.content = tool_output.compress_tool_output(msg.content, config)
    end
    -- Preserve critical entities from original content if it was large
    if #original_content > 2000 then
        local entities = helpers._extract_critical_entities(original_content)
        local has_entities = false
        local entity_parts = {}
        if #entities.files > 0 then
            has_entities = true
            table.insert(entity_parts, "- Files: " .. table.concat(entities.files, ", "))
        end
        if #entities.errors > 0 then
            has_entities = true
            table.insert(entity_parts, "- Errors: " .. table.concat(entities.errors, "; "))
        end
        if #entities.decisions > 0 then
            has_entities = true
            table.insert(entity_parts, "- Decisions: " .. table.concat(entities.decisions, "; "))
        end
        if #entities.functions > 0 then
            has_entities = true
            table.insert(entity_parts, "- Functions: " .. table.concat(entities.functions, ", "))
        end
        if has_entities then
            msg.content = msg.content .. "\n[PRESERVED_ENTITIES]\n" .. table.concat(entity_parts, "\n") .. "\n[/PRESERVED_ENTITIES]"
        end
    end
    return msg
end
return M
