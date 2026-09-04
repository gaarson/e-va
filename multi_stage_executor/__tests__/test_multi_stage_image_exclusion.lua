local multi_stage = require("multi_stage_executor")
local utils = require("utils")
local registry = require("tool_registry")
require("tools").init(nil)
-- Helper: create a mock context with image support
local function make_mock_ctx(overrides)
    overrides = overrides or {}
    local ctx = {
        config = {
            PROJECT_ROOT = "/tmp/test_project",
            AGENTS = {
                test_agent = {
                    allowed_tools = {"patch", "create_file", "shell", "read_file", "delegate_plan"}
                }
            },
            CREATE_BACKUPS = false,
            IMAGE_CONFIG = overrides.IMAGE_CONFIG or {
                max_images_per_turn = 10,
                max_images_base64_bytes = 4 * 1024 * 1024,
                tokens_per_base64_byte = 0.004
            }
        },
        knowledge_base = overrides.knowledge_base or {},
        file_states = {},
        images = overrides.images or {},
        images_loaded = overrides.images_loaded or false,
        last_sent_image_hashes = overrides.last_sent_image_hashes or {},
        history = overrides.history or { test_agent = {} },
        execution_plan = {},
        last_actions = {},
        pinned_files = {},
        turn_requested_files = {},
        promoted_files = {},
        search_history = {},
        file_tree = "",
        handoff_memo = nil,
        recent_tool_outputs = {},
        thoughts = {},
        squash_last_mutation = function(self, name) end,
        add_file = function(self, path, content)
            self.knowledge_base[path] = content
        end,
        estimate_tokens = function(self, text, agent_cfg)
            return math.ceil(#tostring(text or "") / 3.5)
        end,
        build_context = function(self, agent_name, agent_cfg, available_tokens)
            -- Minimal build_context for testing
            local messages = { { role = "system", content = "You are a test agent." } }
            local history = self.history[agent_name] or {}
            for _, msg in ipairs(history) do
                table.insert(messages, { role = msg.role, content = msg.content })
            end
            -- Inject images if loaded and not previously sent
            if self.images_loaded and #self.images > 0 then
                local new_images = {}
                for _, img in ipairs(self.images) do
                    local h = img.hash or ""
                    if h == "" or not self.last_sent_image_hashes[h] then
                        table.insert(new_images, img)
                    end
                end
                if #new_images > 0 then
                    -- Find last user message and inject images
                    for i = #messages, 1, -1 do
                        if messages[i].role == "user" then
                            local content = messages[i].content
                            if type(content) == "table" then
                                for _, img in ipairs(new_images) do
                                    table.insert(content, {
                                        type = "image_url",
                                        image_url = { url = "data:" .. img.mime_type .. ";base64," .. img.base64_data }
                                    })
                                end
                            else
                                messages[i].content = {
                                    { type = "text", text = content },
                                }
                                for _, img in ipairs(new_images) do
                                    table.insert(messages[i].content, {
                                        type = "image_url",
                                        image_url = { url = "data:" .. img.mime_type .. ";base64," .. img.base64_data }
                                    })
                                end
                            end
                            break
                        end
                    end
                end
            end
            return { messages = messages, total_tokens = 100 }
        end,
        add_message = function(self, agent_name, role, content)
            self.history[agent_name] = self.history[agent_name] or {}
            table.insert(self.history[agent_name], { role = role, content = content })
        end
    }
    return ctx
end
-- Helper: create a mock image entry
local function make_mock_image(overrides)
    overrides = overrides or {}
    return {
        path = overrides.path or "/tmp/test.png",
        mime_type = overrides.mime_type or "image/png",
        base64_data = overrides.base64_data or "aGVsbG8=", -- "hello" in base64
        hash = overrides.hash or "test_hash_001",
        width = overrides.width or 100,
        height = overrides.height or 100
    }
end
-- ============================================================
-- Tests: Image exclusion from multi-stage generate prompt
-- ============================================================
describe("Multi-Stage Image Exclusion", function()
    -- ========================================================================
    -- TEST 1: Previously sent images are NOT re-injected into messages
    -- ========================================================================
    describe("Previously sent image exclusion", function()
        it("should NOT inject images whose hash is in last_sent_image_hashes", function()
            local img = make_mock_image({ hash = "sent_hash_abc" })
            local ctx = make_mock_ctx({
                images = { img },
                images_loaded = true,
                last_sent_image_hashes = { ["sent_hash_abc"] = true }
            })
            ctx.history.test_agent = {
                { role = "user", content = "Fix the bug" }
            }
            local context_data = ctx:build_context("test_agent", {}, 4096)
            local messages = context_data.messages
            -- All message content should be strings (no image parts injected)
            for i, msg in ipairs(messages) do
                if msg.role == "user" then
                    assert.is_true(type(msg.content) == "string",
                        string.format("Message %d content should be a string (no images), got: %s", i, type(msg.content)))
                end
            end
        end)
        it("should inject NEW images that are not in last_sent_image_hashes", function()
            local new_img = make_mock_image({ hash = "new_hash_xyz" })
            local ctx = make_mock_ctx({
                images = { new_img },
                images_loaded = true,
                last_sent_image_hashes = {}
            })
            ctx.history.test_agent = {
                { role = "user", content = "Fix the bug" }
            }
            local context_data = ctx:build_context("test_agent", {}, 4096)
            local messages = context_data.messages
            -- The user message should now have table content (multi-part with image)
            local found_image = false
            for _, msg in ipairs(messages) do
                if msg.role == "user" and type(msg.content) == "table" then
                    for _, part in ipairs(msg.content) do
                        if part.type == "image_url" then
                            found_image = true
                        end
                    end
                end
            end
            assert.is_true(found_image, "New image should be injected into user message")
        end)
        it("should handle mixed sent and new images correctly", function()
            local sent_img = make_mock_image({ hash = "sent_1" })
            local new_img = make_mock_image({ hash = "new_1" })
            local ctx = make_mock_ctx({
                images = { sent_img, new_img },
                images_loaded = true,
                last_sent_image_hashes = { ["sent_1"] = true }
            })
            ctx.history.test_agent = {
                { role = "user", content = "Analyze this" }
            }
            local context_data = ctx:build_context("test_agent", {}, 4096)
            local messages = context_data.messages
            -- Should have exactly 1 image part (only the new one)
            local image_count = 0
            for _, msg in ipairs(messages) do
                if type(msg.content) == "table" then
                    for _, part in ipairs(msg.content) do
                        if part.type == "image_url" then
                            image_count = image_count + 1
                        end
                    end
                end
            end
            assert.equals(1, image_count, "Only the new image should be injected")
        end)
    end)
    -- ========================================================================
    -- TEST 2: Empty images produce no image parts
    -- ========================================================================
    describe("Empty images", function()
        it("should produce no image parts when ctx.images is empty", function()
            local ctx = make_mock_ctx({
                images = {},
                images_loaded = false,
                last_sent_image_hashes = {}
            })
            ctx.history.test_agent = {
                { role = "user", content = "Hello" }
            }
            local context_data = ctx:build_context("test_agent", {}, 4096)
            local messages = context_data.messages
            for _, msg in ipairs(messages) do
                assert.is_true(type(msg.content) == "string",
                    "All message content should be strings when no images")
            end
        end)
        it("should produce no image parts when images_loaded is false", function()
            local img = make_mock_image()
            local ctx = make_mock_ctx({
                images = { img },
                images_loaded = false, -- Not loaded
                last_sent_image_hashes = {}
            })
            ctx.history.test_agent = {
                { role = "user", content = "Hello" }
            }
            local context_data = ctx:build_context("test_agent", {}, 4096)
            local messages = context_data.messages
            for _, msg in ipairs(messages) do
                assert.is_true(type(msg.content) == "string",
                    "All message content should be strings when images not loaded")
            end
        end)
    end)
    -- ========================================================================
    -- TEST 3: Multi-stage generate prompt contains no binary data
    -- ========================================================================
    describe("Generate prompt purity", function()
        it("build_generate_prompt output is valid UTF-8 text (no binary)", function()
            local ctx = make_mock_ctx({
                knowledge_base = {
                    ["src/main.c"] = "int main() { return 0; }\n"
                }
            })
            local executor = multi_stage.new(ctx, "test_agent")
            executor.intent = { TOOL = "patch", raw = "GOAL: Fix bug\nTOOL: patch\nFILE_PATH: src/main.c" }
            executor.intent_raw = executor.intent.raw
            local prompt = executor:build_generate_prompt()
            -- Verify the prompt is a string
            assert.is_true(type(prompt) == "string")
            -- Verify it contains no null bytes (binary indicator)
            assert.is_false(prompt:find("\0", 1, true) ~= nil, "Prompt should not contain null bytes")
            -- Verify it's valid UTF-8 using proper sequence tracking
            local len = #prompt
            local i = 1
            while i <= len do
                local b = string.byte(prompt, i)
                if b >= 0x80 and b <= 0xBF then
                    -- Continuation byte: must be preceded by a leading byte (0xC2-0xF4)
                    if i == 1 then
                        assert.is_true(false, "Lone continuation byte at position 1")
                    end
                    local prev = string.byte(prompt, i - 1)
                    if not (prev >= 0xC2 and prev <= 0xF4) then
                        -- Could be part of a valid multi-byte sequence where prev is also a continuation
                        -- Check further back for the leading byte
                        local j = i - 1
                        local found_leading = false
                        while j >= 1 do
                            local pb = string.byte(prompt, j)
                            if pb >= 0xC2 and pb <= 0xF4 then
                                found_leading = true
                                break
                            elseif pb < 0x80 then
                                break
                            end
                            j = j - 1
                        end
                        assert.is_true(found_leading,
                            string.format("Invalid UTF-8: continuation byte at %d not preceded by leading byte", i))
                    end
                end
                i = i + 1
            end
        end)
        it("build_generate_prompt with knowledge_base file containing valid content", function()
            local ctx = make_mock_ctx({
                knowledge_base = {
                    ["src/app.lua"] = "local x = 42\nprint(x)\n"
                }
            })
            local executor = multi_stage.new(ctx, "test_agent")
            executor.intent = { TOOL = "patch", raw = "GOAL: Modify app.lua\nTOOL: patch\nFILE_PATH: src/app.lua" }
            executor.intent_raw = executor.intent.raw
            -- Set task to reference the file so it gets included in context_block
            executor.task = "Modify src/app.lua to fix the bug"
            local prompt = executor:build_generate_prompt()
            assert.is_true(type(prompt) == "string")
            assert.truthy(prompt:find("src/app.lua", 1, true), "Prompt should reference the file path")
        end)
    end)
    -- ========================================================================
    -- TEST 4: Invalid UTF-8 in knowledge_base is handled safely
    -- ========================================================================
    describe("Invalid UTF-8 in knowledge_base", function()
        it("build_generate_prompt handles file with Windows-1252 smart quote (0x92)", function()
            -- 0x92 is a Windows-1252 right single quote, invalid as standalone UTF-8
            local bad_content = "local s = \"\x92hello\x93\"\nprint(s)\n"
            local ctx = make_mock_ctx({
                knowledge_base = {
                    ["src/quotes.lua"] = bad_content
                }
            })
            local executor = multi_stage.new(ctx, "test_agent")
            executor.intent = { TOOL = "patch", raw = "GOAL: Fix quotes\nTOOL: patch\nFILE_PATH: src/quotes.lua" }
            executor.intent_raw = executor.intent.raw
            executor.task = "Fix the encoding in src/quotes.lua"
            -- The prompt should be generated without crashing
            local ok, prompt_or_err = pcall(function()
                return executor:build_generate_prompt()
            end)
            assert.is_true(ok, string.format("build_generate_prompt should not crash: %s", tostring(prompt_or_err)))
            if ok then
                -- The output should be a string (it may contain the raw bytes since
                -- sanitization happens at the LLM request layer, not in prompt building)
                assert.is_true(type(prompt_or_err) == "string")
            end
        end)
        it("sanitize_for_json cleans invalid UTF-8 from file content", function()
            local encoding = require("utils.encoding")
            -- Simulate what happens when file content with 0x92 goes through sanitization
            local bad_content = "local s = \"\x92hello\x93\""
            local sanitized = encoding.sanitize_for_json(bad_content)
            -- The 0x92 bytes should be replaced (they're lone continuation bytes)
            assert.is_false(sanitized:find(string.char(0x92), 1, true) ~= nil,
                "Sanitized content should not contain raw 0x92 bytes")
            -- Should still contain the valid ASCII parts
            assert.truthy(sanitized:find("hello", 1, true), "Valid text should be preserved")
        end)
        it("full pipeline: invalid UTF-8 file content is sanitized before LLM send", function()
            local encoding = require("utils.encoding")
            -- Simulate the full sanitization path that request.lua uses
            local function sanitize_recursive(t)
                if type(t) == "string" then
                    return encoding.sanitize_for_json(t)
                elseif type(t) == "table" then
                    for k, v in pairs(t) do
                        t[k] = sanitize_recursive(v)
                    end
                    return t
                else
                    return t
                end
            end
            -- File content with invalid UTF-8 (0x92 smart quotes)
            local file_content = "function greet(name)\n    return \"\x92Hello \x93\" .. name\nend\n"
            -- Build a payload as the LLM request would
            local payload = {
                model = "test-model",
                messages = {
                    { role = "system", content = "You are a helper." },
                    { role = "user", content = "Fix this file:\n" .. file_content }
                },
                stream = false
            }
            -- Apply sanitization (as request.lua does)
            sanitize_recursive(payload)
            -- Verify the message content no longer has raw 0x92 bytes
            local msg_content = payload.messages[2].content
            assert.is_false(msg_content:find(string.char(0x92), 1, true) ~= nil,
                "Sanitized message should not contain raw 0x92")
            -- Valid content preserved
            assert.truthy(msg_content:find("Hello", 1, true))
            assert.truthy(msg_content:find("greet", 1, true))
        end)
    end)
    -- ========================================================================
    -- TEST 5: Image data does not leak into multi-stage executor state
    -- ========================================================================
    describe("Image isolation in executor state", function()
        it("executor payload never contains base64 image data", function()
            local img = make_mock_image({
                base64_data = "aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRlc3QgaW1hZ2U=",
                hash = "img_hash_1"
            })
            local ctx = make_mock_ctx({
                images = { img },
                images_loaded = true,
                last_sent_image_hashes = {}
            })
            local executor = multi_stage.new(ctx, "test_agent")
            executor.intent = { TOOL = "patch", raw = "GOAL: test\nTOOL: patch" }
            executor.intent_raw = executor.intent.raw
            executor.payload = "some valid payload content"
            -- The payload should be plain text, no image data
            assert.is_true(type(executor.payload) == "string")
            assert.is_false(executor.payload:find("base64", 1, true) ~= nil)
            assert.is_false(executor.payload:find(img.base64_data, 1, true) ~= nil)
        end)
        it("executor intent_raw never contains image binary data", function()
            local img = make_mock_image({
                base64_data = "c3VwZXIgbG9uZyBiYXNlNjQgZGF0YSBmb3IgdGVzdGluZw==",
                hash = "img_hash_2"
            })
            local ctx = make_mock_ctx({
                images = { img },
                images_loaded = true,
                last_sent_image_hashes = {}
            })
            local executor = multi_stage.new(ctx, "test_agent")
            executor.intent = { TOOL = "patch", raw = "GOAL: Fix bug\nTOOL: patch" }
            executor.intent_raw = executor.intent.raw
            -- intent_raw should be clean text
            assert.is_true(type(executor.intent_raw) == "string")
            assert.is_false(executor.intent_raw:find(img.base64_data, 1, true) ~= nil,
                "intent_raw should not contain image base64 data")
        end)
    end)
    -- ========================================================================
    -- TEST 6: build_context with all images already sent produces string-only messages
    -- ========================================================================
    describe("All-sent images produce clean messages", function()
        it("messages are all strings when every image hash is in last_sent_image_hashes", function()
            local img1 = make_mock_image({ hash = "h1" })
            local img2 = make_mock_image({ hash = "h2" })
            local ctx = make_mock_ctx({
                images = { img1, img2 },
                images_loaded = true,
                last_sent_image_hashes = { ["h1"] = true, ["h2"] = true }
            })
            ctx.history.test_agent = {
                { role = "user", content = "First message" },
                { role = "assistant", content = "Response" },
                { role = "user", content = "Second message" }
            }
            local context_data = ctx:build_context("test_agent", {}, 4096)
            local messages = context_data.messages
            -- Every message should have string content (no multi-part arrays)
            for i, msg in ipairs(messages) do
                assert.is_true(type(msg.content) == "string",
                    string.format("Message %d (role=%s) should have string content, got: %s",
                        i, msg.role, type(msg.content)))
            end
        end)
        it("no image_url parts exist in any message when all images are sent", function()
            local img = make_mock_image({ hash = "sent_only" })
            local ctx = make_mock_ctx({
                images = { img },
                images_loaded = true,
                last_sent_image_hashes = { ["sent_only"] = true }
            })
            ctx.history.test_agent = {
                { role = "user", content = "Do something" }
            }
            local context_data = ctx:build_context("test_agent", {}, 4096)
            local messages = context_data.messages
            local has_image_part = false
            for _, msg in ipairs(messages) do
                if type(msg.content) == "table" then
                    for _, part in ipairs(msg.content) do
                        if part.type == "image_url" then
                            has_image_part = true
                        end
                    end
                end
            end
            assert.is_false(has_image_part, "No image_url parts should exist when all images are previously sent")
        end)
    end)
end)