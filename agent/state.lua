local ui = require("ui")
local json = require("JSON")
local M = {}
--- Gets the state file path based on config
-- @param config: The configuration table
-- @return string: Path to the state file
function M.get_state_file_path(config)
    return config.PROJECT_ROOT .. "/.e-va-conf/.state.json"
end
--- Verifies a state file by reading, decoding, and validating its structure.
-- @param state_file: Path to the state file
-- @return boolean: true if valid, false otherwise
function M.verify_state_file(state_file)
    local content = io.open(state_file, "r")
    if not content then return false end
    local data = content:read("*all")
    content:close()
    if not data or #data == 0 then return false end
    local ok, state = pcall(function() return json:decode(data) end)
    if not ok or not state then return false end
    -- Use context.state.validate_snapshot if available
    local state_mod = require("context.state")
    if type(state_mod.validate_snapshot) == "function" then
        return state_mod.validate_snapshot(state)
    end
    return true
end
--- Saves the current context snapshot to the state file using atomic write.
-- Writes to .tmp first, creates .bak backup of existing file, then renames.
-- @param ctx: The ContextFlow instance
-- @param state_file: Path to the state file
function M.save_state(ctx, state_file)
    local snap = ctx:snapshot()
    if not snap then return end
    local ok, err = pcall(function()
        -- Ensure directory exists
        local dir = state_file:match("(.*[/\\])")
        if dir then
            os.execute(string.format("mkdir -p '%s'", dir))
        end
        -- Create backup of existing state file
        local bak_file = state_file .. ".bak"
        local existing = io.open(state_file, "r")
        if existing then
            local existing_data = existing:read("*all")
            existing:close()
            local bak_f = io.open(bak_file, "w")
            if bak_f then
                bak_f:write(existing_data)
                bak_f:close()
            end
        end
        -- Write to temp file first
        local tmp_file = state_file .. ".tmp"
        local f = io.open(tmp_file, "w")
        if not f then error("Cannot open temp file for writing") end
        f:write(snap)
        f:close()
        -- Atomic rename
        os.rename(tmp_file, state_file)
    end)
    if not ok then
        -- Clean up temp file on failure
        os.execute(string.format("rm -f '%s.tmp'", state_file))
        ui.print_error(string.format("[STATE SAVE FAILED] %s", tostring(err)))
    end
end
--- Cleans up all state-related files (.state.json, .state.json.tmp, .state.json.bak)
-- @param state_file: Path to the state file (base path without extensions)
function M.cleanup_state(state_file)
    os.remove(state_file)
    os.remove(state_file .. ".tmp")
    os.remove(state_file .. ".bak")
end

--- Prompts user to restore previous session if state file exists
-- Tries .state.json first, then falls back to .state.json.bak if primary fails.
-- @param state_file: Path to the state file
-- @param ctx: The ContextFlow instance
-- @param utils: The utils module (for read_file_range)
-- @return boolean: true if session was restored, false otherwise
function M.restore_session(state_file, ctx, utils)
    local bak_file = state_file .. ".bak"
    local state_file_exists = utils.read_file_range(state_file) ~= nil
    local bak_file_exists = utils.read_file_range(bak_file) ~= nil
    if not state_file_exists and not bak_file_exists then
        return false
    end
    local should_restore = ui.security_prompt.confirm_session_restore()
    if not should_restore then
        -- User chose not to continue: delete all state files and start fresh
        M.cleanup_state(state_file)
        ui.printer.line("\n[SYSTEM] Discarded previous session. Starting fresh.")
        return false
    end
    -- Try primary state file first
    if state_file_exists then
        local content = utils.read_file_range(state_file)
        if content and ctx:load_from_snapshot(content) then
            ui.print_success("[SYSTEM] Restored previous session from primary state file.")
            return true
        end
    end
    -- Fall back to backup file
    if bak_file_exists then
        ui.print_warning("[SYSTEM] Primary state file failed. Trying backup...")
        local content = utils.read_file_range(bak_file)
        if content and ctx:load_from_snapshot(content) then
            ui.print_success("[SYSTEM] Restored previous session from backup state file.")
            -- Replace corrupted primary with backup
            local bak_content = utils.read_file_range(bak_file)
            local f = io.open(state_file, "w")
            if f then
                f:write(bak_content)
                f:close()
            end
            return true
        end
    end
    -- Both failed: clean up corrupted files
    ui.print_error("[SYSTEM] Failed to restore session from both primary and backup. Starting fresh.")
    M.cleanup_state(state_file)
    return false
end
return M