local M = {}

--- Gets the state file path based on config
-- @param config: The configuration table
-- @return string: Path to the state file
function M.get_state_file_path(config)
    return config.PROJECT_ROOT .. "/.e-va-conf/.state.json"
end

--- Saves the current context snapshot to the state file
-- @param ctx: The ContextFlow instance
-- @param state_file: Path to the state file
function M.save_state(ctx, state_file)
    local snap = ctx:snapshot()
    if snap then
        -- Ensure directory exists
        local dir = state_file:match("(.*[/\\])")
        if dir then
            os.execute(string.format("mkdir -p '%s'", dir))
        end
        local f = io.open(state_file, "w")
        if f then
            f:write(snap)
            f:close()
        end
    end
end

--- Prompts user to restore previous session if state file exists
-- @param state_file: Path to the state file
-- @param ctx: The ContextFlow instance
-- @param utils: The utils module (for read_file_range)
-- @return boolean: true if session was restored, false otherwise
function M.restore_session(state_file, ctx, utils)
    local state_file_exists = utils.read_file_range(state_file) ~= nil
    if not state_file_exists then
        return false
    end

    io.write("\n\27[33m[SYSTEM] Previous session found. Continue (y) or start new (n)?\27[0m ")
    io.flush()
    local user_choice = io.read("*l")

    if user_choice and (user_choice:lower() == "y" or user_choice:lower() == "yes") then
        local content = utils.read_file_range(state_file)
        if content and ctx:load_from_snapshot(content) then
            print("\n\27[32m[SYSTEM] Restored previous session.\27[0m")
            return true
        else
            print("\n\27[31m[SYSTEM] Failed to restore session. Starting fresh.\27[0m")
            return false
        end
    else
        -- User chose not to continue: delete state file and start fresh
        os.remove(state_file)
        print("\n\27[36m[SYSTEM] Discarded previous session. Starting fresh.\27[0m")
        return false
    end
end

return M