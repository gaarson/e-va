local llm = require("llm_handler")
local utils = require("utils")
local json = require("JSON")
local config = require("config").get()

local target_agent = nil
if type(arg) == "table" and type(arg) == "string" and utils.trim(arg) ~= "" then
    target_agent = utils.trim(arg)
end

local agents_to_test = {}

if target_agent then
    if type(config.AGENTS) ~= "table" or not config.AGENTS[target_agent] then
        print(string.format("\n\27[31m[ERROR] Agent '%s' not found in config.lua\27[0m", target_agent))
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
    print(string.format("\n\27[35m>>> TESTING AGENT PROFILE: %s <<<\27[0m", agent_name))
    print("Endpoint: " .. tostring(profile.url))
    print("Model:    " .. tostring(profile.model))
    print("--------------------------------------------------")

    -- ==========================================
    -- TEST 1: Synchronous JSON Payload
    -- ==========================================
    print("\27[33m[TEST 1/3]: Synchronous Payload (Non-Streaming)...\27[0m")
    local res_sync, err_sync = llm.send_request(profile, test_messages, { override_params = { stream = false, max_tokens = 100 } })
    if not res_sync then
        print("\27[31m[FAIL]\27[0m Network/Parsing error: " .. tostring(err_sync))
    else
        local content = llm.extract_content(res_sync)
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
    print("\n\27[33m[TEST 2/3]: SSE Chunk Assembly (Streaming)...\27[0m")
    local stream_buffer = ""
    io.write("Stream incoming: \27[90m")
    local res_stream, err_stream = llm.send_request(profile, test_messages, {
        override_params = { stream = true, max_tokens = 100 },
        on_token = function(t)
            io.write(t)
            io.flush()
            stream_buffer = stream_buffer .. t
        end
    })
    io.write("\27[0m\n")

    if not res_stream then
        print("\27[31m[FAIL]\27[0m Streaming connection failed: " .. tostring(err_stream))
    else
        if #stream_buffer > 0 then
            print("\27[32m[SUCCESS]\27[0m SSE chunks parsed correctly.")
        else
            print("\27[31m[FAIL]\27[0m Stream buffer is empty. The parser in llm_handler.lua failed to extract 'delta.content'.")
        end
    end

    -- ==========================================
    -- TEST 3: Strict Validation (Raw Config Params)
    -- ==========================================
    print("\n\27[33m[TEST 3/3]: Strict Parameter Validation...\27[0m")
    local res_strict, err_strict = llm.send_request(profile, test_messages)
    
    if not res_strict then
        print("\27[31m[FAIL]\27[0m Request rejected using raw config.lua parameters: " .. tostring(err_strict))
        print("         [!] If HTTP 400/422, your API likely rejects specific samplers (e.g., smoothing_factor, min_p, token_healing).")
        print("         [!] ACTION: Clean up the 'params' table for this agent in config.lua.")
    else
        print("\27[32m[SUCCESS]\27[0m Endpoint fully accepts your config.lua parameters.")
    end
end

print("\n\27[36m=== DIAGNOSTIC COMPLETE ===\27[0m\n")
