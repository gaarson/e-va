local llm = require("llm_handler")
local utils = require("utils")
local json = require("JSON")
local config = require("config").get()
local os = require("os")

-- Утилиты для красивого логирования
local function log_step(step_name, detail)
    print(string.format("\n\27[36m[STEP: %s]\27[0m %s", step_name, detail or ""))
end

local function log_debug(msg)
    print(string.format("\27[90m[DEBUG] %s\27[0m", msg))
end

log_step("INIT", "Booting E-VA API Tester with Ultra-Verbose Logging")

local target_agent = nil
if type(arg) == "table" and type(arg) == "string" and utils.trim(arg) ~= "" then
    target_agent = utils.trim(arg)
    log_debug("Target agent specified via CLI: " .. target_agent)
else
    log_debug("No specific agent provided via CLI. Will test all agents from config.")
end

local agents_to_test = {}

if target_agent then
    if type(config.AGENTS) ~= "table" or not config.AGENTS[target_agent] then
        print(string.format("\n\27[31m[FATAL] Agent '%s' not found in config.lua\27[0m", target_agent))
        os.exit(1)
    end
    agents_to_test[target_agent] = config.AGENTS[target_agent]
else
    if type(config.AGENTS) ~= "table" then
        print("\n\27[31m[FATAL] config.AGENTS is not a valid table.\27[0m")
        os.exit(1)
    end
    agents_to_test = config.AGENTS
end

print("\n\27[36m=== E-VA API CONFIGURATION DIAGNOSTIC ===\27[0m")

local test_messages = {
    { role = "system", content = "You are a test diagnostic protocol. Be extremely concise." },
    { role = "user", content = "Respond with exactly one word: 'ACKNOWLEDGE'." }
}

for agent_name, profile in pairs(agents_to_test) do
    print(string.format("\n\27[35m========== TESTING AGENT PROFILE: %s ==========\27[0m", agent_name))
    log_debug("Endpoint URL : " .. tostring(profile.url))
    log_debug("Model ID     : " .. tostring(profile.model))
    log_debug("Provider     : " .. tostring(profile.provider or "openai (default engine)"))
    log_debug("Base Params  : " .. json:encode(profile.params or {}))
    print("--------------------------------------------------")

    -- ==========================================
    -- TEST 1: Synchronous JSON Payload
    -- ==========================================
    log_step("TEST 1/3", "Synchronous Payload (Non-Streaming)")
    log_debug("Sending standard POST request with stream=false...")
    
    local res_sync, err_sync = llm.send_request(profile, test_messages, { override_params = { stream = false, max_tokens = 100 } })
    
    if not res_sync then
        print("\27[31m[FAIL]\27[0m Network/Parsing error: " .. tostring(err_sync))
    else
        log_debug("Sync Request successful. Raw table received. Extracting content...")
        local content = llm.extract_content(res_sync, profile.provider)
        if content and utils.trim(content) ~= "" then
            print("\27[32m[SUCCESS]\27[0m Valid schema. Response: " .. utils.trim(content))
        else
            print("\27[33m[WARNING]\27[0m Content is empty or nil! Dumping RAW server response:")
            print("\27[90m" .. json:encode(res_sync) .. "\27[0m")
        end
    end

    -- ==========================================
    -- TEST 2: Server-Sent Events (Streaming)
    -- ==========================================
    log_step("TEST 2/3", "SSE Chunk Assembly (Streaming)")
    log_debug("Sending POST request with stream=true...")
    log_debug("Waiting for the first chunk to arrive on the TCP socket...\n")
    
    local stream_buffer = ""
    local chunk_count = 0
    local start_time = os.time()
    
    local res_stream, err_stream = llm.send_request(profile, test_messages, {
        override_params = { stream = true, max_tokens = 100 },
        on_token = function(token)
            chunk_count = chunk_count + 1
            -- [КЛЮЧЕВОЙ МОМЕНТ ДЛЯ ОТЛАДКИ]
            -- Оборачиваем токен в одинарные кавычки, чтобы видеть пробелы и переносы строк (\n)
            print(string.format("\27[33m[CHUNK #%03d]\27[0m -> '%s'", chunk_count, token))
            stream_buffer = stream_buffer .. token
        end
    })
    
    local end_time = os.time()
    local duration = end_time - start_time
    
    log_step("STREAMING FINISHED", string.format("Received %d chunks in ~%d seconds.", chunk_count, duration))
    
    if not res_stream then
        print("\27[31m[FAIL]\27[0m Streaming connection failed or timed out: " .. tostring(err_stream))
    else
        log_debug("Full assembled text from chunks:\n\27[32m" .. stream_buffer .. "\27[0m")
        if chunk_count > 0 then
            print("\n\27[32m[SUCCESS]\27[0m SSE stream established and chunks parsed correctly.")
        else
            print("\n\27[31m[FAIL]\27[0m Stream buffer is empty (0 chunks).")
            log_debug("POSSIBLE CAUSES:")
            log_debug("1. The API endpoint ignored 'stream=true' and returned a flat JSON block instead of SSE 'data: {...}' lines.")
            log_debug("2. The llm_providers.lua parser failed to extract 'delta.content' from the specific JSON schema of this server.")
        end
    end

    -- ==========================================
    -- TEST 3: Strict Validation (Raw Config Params)
    -- ==========================================
    log_step("TEST 3/3", "Strict Parameter Validation")
    log_debug("Sending raw config.lua parameters without overrides to check for API rejections...")
    
    local res_strict, err_strict = llm.send_request(profile, test_messages)

    if not res_strict then
        print("\27[31m[FAIL]\27[0m Request rejected using raw config.lua parameters: " .. tostring(err_strict))
        log_debug("If you see HTTP 400 or 422, your API server hates one of your samplers.")
        log_debug("Check 'min_p', 'smoothing_factor', or 'token_healing' in your config.lua and disable them for this agent.")
    else
        print("\27[32m[SUCCESS]\27[0m Endpoint fully accepts your config.lua parameters.")
    end
end

print("\n\27[36m=== DIAGNOSTIC COMPLETE ===\27[0m\n")
