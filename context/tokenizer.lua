-- context/tokenizer.lua

-- Token estimation with LRU caching, content-type detection, structural overhead,
-- and model calibration. Extracted from context_flow.lua.
-- All functions take ctx (the context_flow instance) as the first argument.

local M = {}
-- ============================================================================
-- LRU CACHE FOR TOKEN ESTIMATES (HASH-BASED KEYS)
-- ============================================================================
local bit32 = bit32 or require("bit32") or {}
if not bit32.bxor then
    local function bxor(a, b)
        local result, bit = 0, 1
        a, b = math.floor(a), math.floor(b)
        while a > 0 or b > 0 do
            if (a % 2) ~= (b % 2) then result = result + bit end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            bit = bit * 2
        end
        return result
    end
    local function band(a, b)
        local result, bit = 0, 1
        a, b = math.floor(a), math.floor(b)
        while a > 0 and b > 0 do
            if (a % 2) == 1 and (b % 2) == 1 then result = result + bit end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            bit = bit * 2
        end
        return result
    end
    bit32.bxor = bxor
    bit32.band = band
end
local _token_estimate_cache = {}   -- hash -> { prefix, len, value }
local _cache_order = {}            -- ordered list of hashes
local _cache_positions = {}        -- hash -> position in _cache_order
local _cache_max_size_default = 1000
-- FNV-1a 32-bit hash for fast, deterministic text hashing
local function _text_hash(text)
    local hash = 2166136261  -- FNV offset basis
    for i = 1, #text do
        hash = bit32.bxor(hash, string.byte(text, i))
        hash = bit32.band(hash * 16777619, 0xFFFFFFFF)  -- FNV prime, mask to 32 bits
    end
    return hash
end
local function _get_cache_max_size(flow_config)
    if flow_config and flow_config.token_estimation and flow_config.token_estimation.cache_size then
        return flow_config.token_estimation.cache_size
    end
    return _cache_max_size_default
end
local function _cache_get(text, model_key)
    if not text then return nil end
    local h = _text_hash(text .. "|" .. (model_key or ""))
    local entry = _token_estimate_cache[h]
    if entry and entry.prefix == text:sub(1, 50) and entry.len == #text then
        return entry.value
    end
    return nil
end
local function _cache_set(text, value, flow_config, model_key)
    if not text then return end
    local h = _text_hash(text .. "|" .. (model_key or ""))
    local max_size = _get_cache_max_size(flow_config)
    local prefix = text:sub(1, 50)
    local len = #text
    -- If already in cache (hash + collision check), move to end (update recency) in O(1)
    local existing = _token_estimate_cache[h]
    if existing and existing.prefix == prefix and existing.len == len then
        local old_pos = _cache_positions[h]
        local last_pos = #_cache_order
        if old_pos ~= last_pos then
            -- Swap with last element
            local last_key = _cache_order[last_pos]
            _cache_order[old_pos] = last_key
            _cache_positions[last_key] = old_pos
            _cache_order[last_pos] = h
            _cache_positions[h] = last_pos
        end
        _token_estimate_cache[h].value = value
        return
    end
    -- Evict oldest if at capacity
    if #_cache_order >= max_size then
        local oldest = _cache_order[1]
        _token_estimate_cache[oldest] = nil
        _cache_positions[oldest] = nil
        -- Shift all positions down by 1 and shift array
        for i = 1, #_cache_order - 1 do
            _cache_order[i] = _cache_order[i + 1]
            _cache_positions[_cache_order[i]] = i
        end
        table.remove(_cache_order)
    end
    -- Insert new entry (keyed by hash, collision-safe via prefix+len)
    table.insert(_cache_order, h)
    _cache_positions[h] = #_cache_order
    _token_estimate_cache[h] = { prefix = prefix, len = len, value = value }
end

-- ============================================================================
-- MODEL DIVISORS (chars per token)
-- ============================================================================

M.MODEL_DIVISORS = {
    ['gpt-4o'] = { code = 2.8, prose = 3.8, mixed = 3.2, xml_json = 3.4 },
    ['gpt-4'] = { code = 2.7, prose = 3.7, mixed = 3.1, xml_json = 3.3 },
    ['gpt-3.5-turbo'] = { code = 2.6, prose = 3.6, mixed = 3.0, xml_json = 3.2 },
    ['claude-3-opus'] = { code = 3.0, prose = 4.0, mixed = 3.5, xml_json = 3.6 },
    ['claude-3-sonnet'] = { code = 3.0, prose = 4.0, mixed = 3.5, xml_json = 3.6 },
    ['claude-3-haiku'] = { code = 3.0, prose = 4.0, mixed = 3.5, xml_json = 3.6 },
    ['default'] = { code = 2.5, prose = 3.5, mixed = 3.0, xml_json = 3.2 }
}

-- ============================================================================
-- CONTENT TYPE DETECTION
-- ============================================================================

local function _detect_content_type(text)
    local len = #text
    if len == 0 then return "empty" end
    local code_score = 0
    local xml_json_score = 0
    local prose_score = 0
    -- Code indicators
    if text:match("function%s+") or text:match("def%s+") or text:match("class%s+") or
       text:match("struct%s+") or text:match("import%s+") or text:match("require%(") or
       text:match("local%s+") or text:match("var%s+") or text:match("let%s+") or
       text:match("const%s+") or text:match("public%s+") or text:match("private%s+") or
       text:match("static%s+") or text:match("void%s+") or text:match("int%s+") or
       text:match("return%s+") or text:match("if%s+") or text:match("for%s+") or
       text:match("while%s+") or text:match("switch%s+") or text:match("case%s+") then
        code_score = code_score + 3
    end
    -- Code block markers
    local fence_count = 0
    for _ in text:gmatch("```") do fence_count = fence_count + 1 end
    if fence_count > 0 then code_score = code_score + 2 end
    -- Braces/brackets density (code tends to have more)
    local brace_count = 0
    for _ in text:gmatch("[{}()\\[\\]]") do brace_count = brace_count + 1 end
    if brace_count > len * 0.02 then code_score = code_score + 1 end
    -- XML/JSON indicators
    if text:match("<[a-zA-Z_][a-zA-Z0-9_-]*%s") or text:match("</[a-zA-Z_]") or
       text:match("<[a-zA-Z_][a-zA-Z0-9_-]*>") then
        xml_json_score = xml_json_score + 2
    end
    if text:match('^%s*[{\\[]') or text:match('"[^"]*"%s*:') then
        xml_json_score = xml_json_score + 2
    end
    -- Prose indicators (long sentences, punctuation)
    local sentence_count = 0
    for _ in text:gmatch("[.!?]%s") do sentence_count = sentence_count + 1 end
    if sentence_count > 3 then prose_score = prose_score + 2 end
    -- Average word length (prose tends to have shorter words)
    local word_count = 0
    local total_word_len = 0
    for word in text:gmatch("%S+") do
        word_count = word_count + 1
        total_word_len = total_word_len + #word
    end
    if word_count > 0 then
        local avg_word_len = total_word_len / word_count
        if avg_word_len < 5 then prose_score = prose_score + 1 end
    end
    -- Decision
    if code_score >= 4 then return "code" end
    if xml_json_score >= 3 then return "xml_json" end
    if code_score >= 2 then return "mixed" end
    if prose_score >= 2 then return "prose" end
    return "mixed" -- default fallback
end

-- ============================================================================
-- STRUCTURAL OVERHEAD CALCULATION
-- ============================================================================

local function _calculate_structural_overhead(text, content_type)
    local overhead = 0
    -- XML tags: each tag adds ~2-3 tokens
    local xml_tag_count = 0
    for _ in text:gmatch("</?[a-zA-Z_][a-zA-Z0-9_-]*[^>]*>") do
        xml_tag_count = xml_tag_count + 1
    end
    if xml_tag_count > 0 then
        overhead = overhead + math.ceil(xml_tag_count * 2.5)
    end
    -- JSON structural chars: { } [ ] : ,
    local json_struct_count = 0
    for _ in text:gmatch("[{}\\[\\]:,]") do
        json_struct_count = json_struct_count + 1
    end
    if json_struct_count > 10 then
        overhead = overhead + math.ceil(json_struct_count * 0.5)
    end
    -- Markdown fences
    local fence_count = 0
    for _ in text:gmatch("```") do fence_count = fence_count + 1 end
    if fence_count > 0 then
        overhead = overhead + math.ceil(fence_count * 1.5)
    end
    -- Long identifiers (>30 chars) tend to be tokenized inefficiently
    local long_id_count = 0
    for id in text:gmatch("%S+") do
        if #id > 30 and id:match("^[a-zA-Z0-9_./%-]+$") then
            long_id_count = long_id_count + 1
        end
    end
    if long_id_count > 0 then
        overhead = overhead + long_id_count
    end
    return overhead
end

-- ============================================================================
-- MAIN ENTRY POINT: ESTIMATE TOKENS
-- ============================================================================

function M.estimate_tokens(ctx, text, agent_cfg)
    if not text or #text == 0 then return 0 end
    -- Get model-specific divisors (needed for cache key)
    local model_name = (agent_cfg and agent_cfg.model) or "default"
    local model_divs = M.MODEL_DIVISORS[model_name] or M.MODEL_DIVISORS["default"]
    -- Check cache first
    local cached = _cache_get(text, model_name)
    if cached then return cached end
    -- Detect content type
    local content_type = _detect_content_type(text)
    -- Get content-type divisor from model table
    local model_divisor = model_divs[content_type] or model_divs.mixed
    -- Blend: 80% model-calibrated, 20% content-type heuristic
    local content_fallback = { code = 2.5, prose = 3.5, mixed = 3.0, xml_json = 3.2, empty = 3.5 }
    local content_divisor = content_fallback[content_type] or content_fallback.mixed
    local blended_divisor = model_divisor * 0.8 + content_divisor * 0.2
    -- If agent has explicit chars_per_token override, blend 60/40
    local effective_divisor
    if agent_cfg and agent_cfg.chars_per_token then
        effective_divisor = agent_cfg.chars_per_token * 0.6 + blended_divisor * 0.4
    else
        effective_divisor = blended_divisor
    end
    -- Apply calibration adjustment if available
    if ctx.calibration_data and ctx.calibration_data[model_name] and ctx.calibration_data[model_name].ratio then
        local ratio = ctx.calibration_data[model_name].ratio
        -- Cap adjustment to ±20%
        if ratio > 1.2 then ratio = 1.2 end
        if ratio < 0.8 then ratio = 0.8 end
        effective_divisor = effective_divisor / ratio
    end
    -- Base token estimate
    local raw_tokens = math.ceil(#text / effective_divisor)
    -- Add structural overhead
    local overhead = _calculate_structural_overhead(text, content_type)
    local total = raw_tokens + overhead
    -- Cache the result
    _cache_set(text, total, ctx.flow_config, model_name)
    return total
end

-- ============================================================================
-- CALIBRATION: Learn from actual token counts
-- ============================================================================

function M.calibrate_from_actual(ctx, agent_name, estimated_tokens, actual_tokens)
    if not estimated_tokens or estimated_tokens == 0 or not actual_tokens or actual_tokens == 0 then return end
    local agent_cfg = ctx.config.AGENTS[agent_name]
    local model_name = (agent_cfg and agent_cfg.model) or "default"
    if not ctx.calibration_data then ctx.calibration_data = {} end
    if not ctx.calibration_data[model_name] then
        ctx.calibration_data[model_name] = { samples = {}, ratio = 1.0 }
    end
    local cal = ctx.calibration_data[model_name]
    local ratio = actual_tokens / estimated_tokens
    table.insert(cal.samples, { estimated = estimated_tokens, actual = actual_tokens, ratio = ratio })
    -- Keep last 50 samples for rolling average
    if #cal.samples > 50 then table.remove(cal.samples, 1) end
    -- Compute running average ratio after 10+ samples
    if #cal.samples >= 10 then
        local sum = 0
        for _, s in ipairs(cal.samples) do sum = sum + s.ratio end
        cal.ratio = sum / #cal.samples
    end
end

function M.get_calibration_stats(ctx)
    if not ctx.calibration_data or not next(ctx.calibration_data) then
        return { message = "No calibration data available" }
    end
    local stats = {}
    for model, cal in pairs(ctx.calibration_data) do
        local entry = { model = model, samples = #cal.samples, ratio = cal.ratio }
        if #cal.samples > 0 then
            local min_r, max_r = cal.samples[1].ratio, cal.samples[1].ratio
            for _, s in ipairs(cal.samples) do
                if s.ratio < min_r then min_r = s.ratio end
                if s.ratio > max_r then max_r = s.ratio end
            end
            entry.min_ratio = min_r
            entry.max_ratio = max_r
        end
        table.insert(stats, entry)
    end
    return stats
end

return M