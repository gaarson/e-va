-- loop_guard.lua
-- Multi-layer loop detection and prevention system.
-- Layers: Budget, Action (exact/fuzzy/sequence), Error, Progress, Semantic, Intervention.
-- Pure Lua, no external dependencies.
local M = {}
local socket = require("socket")
local EXPLORATION_TOOLS = {
    read_file = true,
    read_chunk = true,
    search = true,
    outline = true,
    ls = true,
    find = true,
    head = true,
    tail = true,
    grep = true,
    rg = true,
    cat = true,
}
-- ============================================================================
-- POLYNOMIAL HASH (simple, no crypto dependency)
-- ============================================================================
local function poly_hash(str)
    local hash = 5381
    for i = 1, #str do
        hash = ((hash * 33) + str:byte(i)) % 4294967296  -- 2^32
    end
    return hash
end
-- ============================================================================
-- CANONICALIZE ACTION
-- ============================================================================
local function canonicalize_action(tool_name, args)
    if not tool_name then return "" end
    if not args or args == "" then
        return tool_name
    end
    -- Normalize whitespace and line endings
    local normalized = args:gsub("\r\n", "\n"):gsub("\r", "\n")
    -- Collapse multiple whitespace into single space
    normalized = normalized:gsub("%s+", " ")
    -- Trim
    normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")
    -- Truncate very long args to avoid hash collisions on massive payloads
    if #normalized > 500 then
        normalized = normalized:sub(1, 500)
    end
    return tool_name .. ":" .. normalized
end
-- ============================================================================
-- HASH ACTION
-- ============================================================================
local function hash_action(canonical)
    return poly_hash(canonical)
end
-- ============================================================================
-- JACCARD SIMILARITY
-- ============================================================================
local function tokenize(str)
    local tokens = {}
    for word in str:gmatch("%S+") do
        tokens[word] = true
    end
    return tokens
end
local function jaccard_similarity(set_a, set_b)
    local intersection = 0
    for k in pairs(set_a) do
        if set_b[k] then
            intersection = intersection + 1
        end
    end
    local union_count = 0
    for k in pairs(set_a) do union_count = union_count + 1 end
    for k in pairs(set_b) do
        if not set_a[k] then union_count = union_count + 1 end
    end
    if union_count == 0 then return 1.0 end
    return intersection / union_count
end
-- ============================================================================
-- N-GRAM OVERLAP (for semantic layer)
-- ============================================================================
local function get_ngrams(text, n)
    local words = {}
    for w in text:gmatch("%S+") do
        table.insert(words, w)
    end
    local ngrams = {}
    for i = 1, #words - n + 1 do
        local ng = ""
        for j = 0, n - 1 do
            if j > 0 then ng = ng .. " " end
            ng = ng .. words[i + j]
        end
        ngrams[ng] = true
    end
    return ngrams
end
local function ngram_overlap(set_a, set_b)
    if not next(set_a) or not next(set_b) then return 0.0 end
    local intersection = 0
    for k in pairs(set_a) do
        if set_b[k] then intersection = intersection + 1 end
    end
    local min_size = #set_a < #set_b and #set_a or #set_b
    if min_size == 0 then return 0.0 end
    return intersection / min_size
end
-- Helper: count table entries
local function table_count(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end
-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================
function M.new(ctx, config)
    local lg_config = (config and config.LOOP_GUARD) or {}
    local limits = lg_config.limits or {}
    local weights = lg_config.risk_weights or {}
    local interventions = lg_config.intervention_levels or {}
    local exempt_tools = lg_config.exempt_tools or {}
    -- Build exempt set
    local exempt_set = {}
    for _, t in ipairs(exempt_tools) do
        exempt_set[t] = true
    end
    -- Exploration-only tools (read/search/explore, no mutation)
    local self = setmetatable({}, { __index = M })
    self.ctx = ctx
    self.config = lg_config
    self.limits = {
        max_iterations = limits.max_iterations or 100,
        max_seconds = limits.max_seconds or 600,
        max_tokens = limits.max_tokens or 500000,
        max_cost_usd = limits.max_cost_usd or 5.0,
    }
    self.action_window = lg_config.action_window or 20
    self.max_same_action = lg_config.max_same_action or 2
    self.max_same_error = lg_config.max_same_error or 3
    self.fuzzy_threshold = lg_config.fuzzy_threshold or 0.85
    self.max_sequence_period = lg_config.max_sequence_period or 6
    self.progress_stall_window = lg_config.progress_stall_window or 5
    self.progress_stall_threshold = lg_config.progress_stall_threshold or 0.02
    self.risk_weights = {
        exact_dup = weights.exact_dup or 0.30,
        fuzzy_dup = weights.fuzzy_dup or 0.20,
        sequence_loop = weights.sequence_loop or 0.35,
        error_loop = weights.error_loop or 0.40,
        progress_stall = weights.progress_stall or 0.25,
        semantic_loop = weights.semantic_loop or 0.15,
        budget_exceeded = weights.budget_exceeded or 0.50,
    }
    self.intervention_levels = {
        soft_nudge = interventions.soft_nudge or 0.35,
        force_replan = interventions.force_replan or 0.65,
        circuit_breaker = interventions.circuit_breaker or 0.85,
    }
    self.exempt_set = exempt_set
    -- State
    self.action_history = {}          -- window of canonical actions (max 50)
    self.action_hashes = {}           -- rolling window of hashes (last 20)
    self.error_signatures = {}        -- signature -> { count, last_seen_turn }
    self.progress_history = {}        -- { score, turn }
    self.blocked_actions = {}         -- canonical -> true (blocked until cleared)
    self.assistant_outputs = {}       -- last 8 outputs
    self.iteration_count = 0
    self.consecutive_exploration = 0  -- tracks turns with only exploration tools
    self.total_tokens = 0
    self.start_time = socket.gettime()
    self.total_error_count = 0
    self.current_risk = 0.0
    self.is_globally_blocked = false
    self.block_reason = ""
    return self
end
-- ============================================================================
-- BUDGET LAYER
-- ============================================================================
function M:check_hard_limits()
    local elapsed = socket.gettime() - self.start_time
    local issues = {}
    if self.iteration_count >= self.limits.max_iterations then
        table.insert(issues, string.format("Max iterations reached (%d/%d)", self.iteration_count, self.limits.max_iterations))
    end
    if elapsed >= self.limits.max_seconds then
        table.insert(issues, string.format("Time limit exceeded (%.0fs/%ds)", elapsed, self.limits.max_seconds))
    end
    if self.total_tokens >= self.limits.max_tokens then
        table.insert(issues, string.format("Token budget exceeded (%d/%d)", self.total_tokens, self.limits.max_tokens))
    end
    if #issues > 0 then
        self.is_globally_blocked = true
        self.block_reason = "BUDGET: " .. table.concat(issues, "; ")
        return true, self.block_reason
    end
    return false, nil
end
-- ============================================================================
-- ACTION LAYER
-- ============================================================================
function M:canonicalize_action(tool_name, args)
    return canonicalize_action(tool_name, args)
end
function M:hash_action(canonical)
    return hash_action(canonical)
end
function M:check_exact_duplicate(canonical)
    if not canonical or canonical == "" then return false, nil end
    local h = self:hash_action(canonical)
    local window = math.min(#self.action_hashes, self.action_window)
    for i = #self.action_hashes - window + 1, #self.action_hashes do
        if self.action_hashes[i] == h then
            -- Verify by canonical string to avoid hash collision false positives
            if self.action_history[i] == canonical then
                return true, "Exact duplicate action detected in last " .. self.action_window .. " actions"
            end
        end
    end
    return false, nil
end
function M:check_fuzzy_duplicate(canonical)
    if not canonical or canonical == "" then return false, nil, 0.0 end
    -- Extract args part for comparison
    local args_part = canonical:match("^[^:]+:(.*)")
    if not args_part or #args_part < 10 then return false, nil, 0.0 end
    local current_tokens = tokenize(args_part)
    local max_sim = 0.0
    local worst_match = nil
    local window = math.min(#self.action_history, self.action_window)
    for i = #self.action_history - window + 1, #self.action_history do
        local prev = self.action_history[i]
        local prev_args = prev:match("^[^:]+:(.*)")
        if prev_args and prev_args ~= args_part and #prev_args >= 10 then
            local prev_tokens = tokenize(prev_args)
            local sim = jaccard_similarity(current_tokens, prev_tokens)
            if sim > max_sim then
                max_sim = sim
                worst_match = prev
            end
        end
    end
    if max_sim >= self.fuzzy_threshold then
        return true, string.format("Fuzzy duplicate detected (similarity=%.2f, threshold=%.2f)", max_sim, self.fuzzy_threshold), max_sim
    end
    return false, nil, max_sim
end
function M:check_sequence_loop()
    local n = #self.action_history
    if n < 4 then return false, nil end
    local window = math.min(n, self.action_window)
    local start_idx = n - window + 1
    -- Check for repeating patterns of length 2 to max_sequence_period
    for period = 2, self.max_sequence_period do
        if window < period * 2 then break end  -- Need at least 2 repetitions
        local is_pattern = true
        for i = 0, window - period - 1 do
            local idx_a = start_idx + i
            local idx_b = start_idx + i + period
            if idx_b > n then break end
            if self.action_hashes[idx_a] ~= self.action_hashes[idx_b] then
                is_pattern = false
                break
            end
        end
        if is_pattern then
            -- Verify we have at least 2 full repetitions
            local repetitions = math.floor(window / period)
            if repetitions >= 2 then
                return true, string.format("Sequence loop detected: period=%d, repetitions=%d", period, repetitions)
            end
        end
    end
    return false, nil
end
function M:record_action(canonical)
    table.insert(self.action_history, canonical)
    table.insert(self.action_hashes, self:hash_action(canonical))
    -- Maintain window size
    local max_size = 50
    if #self.action_history > max_size then
        table.remove(self.action_history, 1)
        table.remove(self.action_hashes, 1)
    end
end
-- ============================================================================
-- ERROR LAYER
-- ============================================================================
function M:record_error(tool_name, error_msg)
    if not tool_name or not error_msg then return end
    self.total_error_count = self.total_error_count + 1
    -- Create error signature: tool + normalized error
    local normalized_err = error_msg:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #normalized_err > 200 then
        normalized_err = normalized_err:sub(1, 200)
    end
    local signature = tool_name .. "::" .. normalized_err
    if not self.error_signatures[signature] then
        self.error_signatures[signature] = { count = 0, last_seen_turn = 0 }
    end
    self.error_signatures[signature].count = self.error_signatures[signature].count + 1
    self.error_signatures[signature].last_seen_turn = self.iteration_count
end
function M:check_error_loop()
    local current_turn = self.iteration_count
    for sig, entry in pairs(self.error_signatures) do
        if entry.count >= self.max_same_error then
            -- Only block if the error is recent (within last 5 turns)
            if current_turn - entry.last_seen_turn <= 5 then
                return true, string.format("Error loop: '%s' occurred %d times (threshold=%d)", sig, entry.count, self.max_same_error)
            end
        end
    end
    return false, nil
end
-- ============================================================================
-- PROGRESS LAYER
-- ============================================================================
function M:record_progress()
    local ctx = self.ctx
    if not ctx then return end
    local score = 0.0
    -- Factor 1: Plan completion progress
    if ctx.execution_plan and #ctx.execution_plan > 0 then
        local progress = ctx.current_task_index / #ctx.execution_plan
        score = score + progress * 0.4
    end
    -- Factor 2: New files created/modified (positive signal)
    local modified_count = 0
    for _, state in pairs(ctx.file_states or {}) do
        if state == "RECENTLY_MODIFIED" then modified_count = modified_count + 1 end
    end
    score = score + math.min(modified_count * 0.1, 0.3)
    -- Factor 3: Error reduction (fewer errors = higher score)
    local recent_errors = 0
    for _, entry in pairs(self.error_signatures) do
        if self.iteration_count - entry.last_seen_turn <= 3 then
            recent_errors = recent_errors + entry.count
        end
    end
    if recent_errors == 0 then
        score = score + 0.3
    else
        score = score + math.max(0, 0.3 - recent_errors * 0.1)
    end
    table.insert(self.progress_history, { score = score, turn = self.iteration_count })
    -- Keep window
    local max_hist = 50
    if #self.progress_history > max_hist then
        table.remove(self.progress_history, 1)
    end
end
function M:check_progress_stall()
    local n = #self.progress_history
    if n < self.progress_stall_window then return false, nil end
    local recent = {}
    for i = n - self.progress_stall_window + 1, n do
        table.insert(recent, self.progress_history[i].score)
    end
    -- Check if all deltas are below threshold
    local all_stalled = true
    local max_delta = 0.0
    for i = 2, #recent do
        local delta = math.abs(recent[i] - recent[i - 1])
        max_delta = math.max(max_delta, delta)
        if delta >= self.progress_stall_threshold then
            all_stalled = false
            break
        end
    end
    if all_stalled and max_delta < self.progress_stall_threshold then
        return true, string.format("Progress stalled: max delta=%.4f over last %d turns (threshold=%.2f)",
            max_delta, self.progress_stall_window, self.progress_stall_threshold)
    end
    return false, nil
end
-- ============================================================================
-- SEMANTIC LAYER
-- ============================================================================
function M:record_assistant_output(content)
    if not content or content == "" then return end
    -- Trim and normalize
    local normalized = content:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    table.insert(self.assistant_outputs, normalized)
    -- Keep last 8
    if #self.assistant_outputs > 8 then
        table.remove(self.assistant_outputs, 1)
    end
end
function M:check_semantic_loop()
    local n = #self.assistant_outputs
    if n < 3 then return false, nil, 0.0 end

    local max_overlap = 0.0

    -- Compare last output with previous ones using trigrams
    local current = self.assistant_outputs[n]
    local current_ngrams = get_ngrams(current, 3)

    for i = n - 1, math.max(1, n - 5), -1 do
        local prev = self.assistant_outputs[i]
        if #prev >= 20 then
            local prev_ngrams = get_ngrams(prev, 3)
            local overlap = ngram_overlap(current_ngrams, prev_ngrams)
            if overlap > max_overlap then
                max_overlap = overlap
            end
        end
    end

    if max_overlap >= 0.9 then
        return true, string.format("Semantic loop: output overlap=%.2f (threshold=0.90)", max_overlap), max_overlap
    end

    return false, nil, max_overlap
end
-- ============================================================================
-- INTERVENTION LAYER
-- ============================================================================
function M:compute_loop_risk()
    local risk = 0.0
    local reasons = {}
    -- Budget
    local budget_exceeded, budget_msg = self:check_hard_limits()
    if budget_exceeded then
        risk = risk + self.risk_weights.budget_exceeded
        table.insert(reasons, budget_msg)
    end
    -- Error loop
    local err_loop, err_msg = self:check_error_loop()
    if err_loop then
        risk = risk + self.risk_weights.error_loop
        table.insert(reasons, err_msg)
    end
    -- Progress stall
    local stall, stall_msg = self:check_progress_stall()
    if stall then
        risk = risk + self.risk_weights.progress_stall
        table.insert(reasons, stall_msg)
    end
    -- Semantic loop
    local sem_loop, sem_msg, _ = self:check_semantic_loop()
    if sem_loop then
        risk = risk + self.risk_weights.semantic_loop
        table.insert(reasons, sem_msg)
    end
    -- Clamp to [0, 1]
    risk = math.min(1.0, math.max(0.0, risk))
    self.current_risk = risk
    if risk > 0 and #reasons > 0 then
        self.block_reason = table.concat(reasons, "; ")
    end
    return risk, reasons
end
function M:get_intervention(level)
    if level >= self.intervention_levels.circuit_breaker then
        return {
            level = "CIRCUIT_BREAKER",
            message = string.format(
                "[SYSTEM: LOOP GUARD - CRITICAL] Loop risk score: %.2f. The system has detected a severe looping pattern.\n" ..
                "Reasons: %s\n" ..
                "Action: STOP current approach. Re-plan from scratch. Consider completely different strategies.\n" ..
                "Blocked actions will be enforced until risk decreases.",
                self.current_risk, self.block_reason
            ),
            block = true,
        }
    elseif level >= self.intervention_levels.force_replan then
        return {
            level = "FORCE_REPLAN",
            message = string.format(
                "[SYSTEM: LOOP GUARD - WARNING] Loop risk score: %.2f. The system has detected a potential looping pattern.\n" ..
                "Reasons: %s\n" ..
                "Action: Consider changing your approach. Review what you've tried and try something different.\n" ..
                "If the same tool keeps failing, use a different tool or modify your arguments significantly.",
                self.current_risk, self.block_reason
            ),
            block = false,
        }
    elseif level >= self.intervention_levels.soft_nudge then
        return {
            level = "SOFT_NUDGE",
            message = string.format(
                "[SYSTEM: LOOP GUARD - NOTICE] Loop risk score: %.2f. Minor repetition detected.\n" ..
                "Reasons: %s\n" ..
                "Hint: Consider varying your approach or checking if you're making progress toward the goal.",
                self.current_risk, self.block_reason
            ),
            block = false,
        }
    end
    return { level = "NONE", message = "", block = false }
end
function M:block_action(canonical)
    if canonical and canonical ~= "" then
        self.blocked_actions[canonical] = true
    end
end
function M:is_blocked(canonical)
    if self.is_globally_blocked then return true, self.block_reason end
    if canonical and self.blocked_actions[canonical] then
        return true, "Action blocked by loop guard: " .. (self.block_reason or "duplicate/action loop")
    end
    return false, nil
end
function M:clear_block()
    self.is_globally_blocked = false
    self.blocked_actions = {}
    self.block_reason = ""
end
-- ============================================================================
-- MAIN HOOKS
-- ============================================================================
function M:before_tool_call(tool_name, args)
    -- Check if tool is exempt
    if self.exempt_set[tool_name] then return false, nil end
    -- Check hard limits first
    local budget_hit, budget_msg = self:check_hard_limits()
    if budget_hit then
        return true, budget_msg
    end
    -- Canonicalize
    local canonical = self:canonicalize_action(tool_name, args)
    -- Check if already blocked
    local blocked, block_msg = self:is_blocked(canonical)
    if blocked then return true, block_msg end
    -- Exact duplicate check
    local exact_dup, exact_msg = self:check_exact_duplicate(canonical)
    if exact_dup then
        self:block_action(canonical)
        self.current_risk = math.max(self.current_risk, self.risk_weights.exact_dup)
        return true, string.format("Exact duplicate blocked: %s", exact_msg)
    end
    -- Fuzzy duplicate check (warning only, don't block)
    local fuzzy_dup, fuzzy_msg, sim = self:check_fuzzy_duplicate(canonical)
    if fuzzy_dup then
        self.current_risk = math.max(self.current_risk, self.risk_weights.fuzzy_dup)
        -- Don't block on fuzzy alone, but flag it
    end
    -- Sequence loop check
    local seq_loop, seq_msg = self:check_sequence_loop()
    if seq_loop then
        self:block_action(canonical)
        self.current_risk = math.max(self.current_risk, self.risk_weights.sequence_loop)
        return true, string.format("Sequence loop blocked: %s", seq_msg)
    end
    -- Compute overall risk for warnings
    local risk, _ = self:compute_loop_risk()
    if risk >= self.intervention_levels.soft_nudge then
        local intervention = self:get_intervention(risk)
        if intervention.block then
            return true, intervention.message
        end
        -- Return warning but allow execution
        return nil, intervention.message  -- nil = not blocked, but has warning
    end
    return false, nil
end
function M:after_tool_call(tool_name, args, result, ctx)
    -- Record action
    local canonical = self:canonicalize_action(tool_name, args)
    self:record_action(canonical)
    -- Track consecutive exploration turns
    if EXPLORATION_TOOLS[tool_name] then
        self.consecutive_exploration = self.consecutive_exploration + 1
    else
        -- Mutating or other action resets the counter
        self.consecutive_exploration = 0
    end
    -- Record error if result indicates failure
    if result and type(result) == "table" then
        if result.signal == "ERROR" or result.signal == "FAILURE" then
            local err_msg = result.message or result.output or "unknown error"
            self:record_error(tool_name, err_msg)
        end
    end
    -- Update token count if available
    if result and type(result) == "table" and result.tokens then
        self.total_tokens = self.total_tokens + result.tokens
    end
    -- Record progress periodically
    if self.iteration_count % 3 == 0 then
        self:record_progress()
    end
end
function M:on_turn_start(ctx)
    self.iteration_count = self.iteration_count + 1
    -- Check hard limits
    local budget_hit, budget_msg = self:check_hard_limits()
    if budget_hit then
        self.is_globally_blocked = true
        self.block_reason = budget_msg
        return true, budget_msg
    end
    -- Compute overall risk
    local risk, reasons = self:compute_loop_risk()
    if risk >= self.intervention_levels.circuit_breaker then
        self.is_globally_blocked = true
        self.block_reason = table.concat(reasons, "; ")
        return true, self:get_intervention(risk).message
    end
    -- Check consecutive exploration warning (non-blocking, advisory)
    if self.consecutive_exploration >= 3 then
        local warn_msg = string.format(
            "[SYSTEM: EXPLORATION STALL] You have performed %d consecutive turns using only read/search/explore tools without any write/patch/create/delegate actions. " ..
            "STOP exploring and START acting. Pick a file and make a concrete change, or delegate the task. " ..
            "If you are stuck, summarize what you know and propose a specific next step.",
            self.consecutive_exploration
        )
        -- Return warning but do NOT block (allow the turn to proceed with the warning injected)
        return nil, warn_msg
    end
    return false, nil
end
function M:on_turn_end(response_data)
    -- Record assistant output for semantic analysis
    if response_data and response_data.content then
        self:record_assistant_output(response_data.content)
    end
    -- Update token count from response
    if response_data and response_data.usage then
        self.total_tokens = self.total_tokens + (response_data.usage.total_tokens or 0)
    end
    -- Record progress
    self:record_progress()
    -- Decay risk slightly on successful turn completion (no errors)
    if self.current_risk > 0 then
        self.current_risk = math.max(0, self.current_risk - 0.05)
    end
end
-- ============================================================================
-- GETTERS
-- ============================================================================
function M:get_risk_score()
    return self.current_risk
end
function M:get_iteration_count()
    return self.iteration_count
end
function M:get_total_tokens()
    return self.total_tokens
end
function M:get_blocked_actions_count()
    return table_count(self.blocked_actions)
end
function M:get_recent_errors_count()
    local count = 0
    local current_turn = self.iteration_count
    for _, entry in pairs(self.error_signatures) do
        if current_turn - entry.last_seen_turn <= 5 then
            count = count + entry.count
        end
    end
    return count
end
return M
