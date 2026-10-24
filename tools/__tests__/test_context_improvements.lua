-- Tests for context management improvements (steps 1-4)
describe("Context Improvements", function()
    local json = require("JSON")
    -- Helper: create a minimal mock ctx with stub methods
    local function make_mock_ctx(overrides)
        overrides = overrides or {}
        local ctx = {
            config = { PROJECT_ROOT = "/tmp/test_project" },
            flow_config = {
                storage = { include_pinned_in_recency = true },
                token_estimation = { chars_per_token = 3.5 },
                compression = { enabled = false },
            },
            knowledge_base = overrides.knowledge_base or {},
            file_states = overrides.file_states or {},
            pinned_files = overrides.pinned_files or {},
            turn_requested_files = overrides.turn_requested_files or {},
            promoted_files = overrides.promoted_files or {},
            execution_plan = overrides.execution_plan or {},
            last_actions = {},
            current_turn = 0,
            global_access_counter = 0,
            file_access_rank = {},
            search_history = {},
            recent_tool_outputs = {},
        }
        ctx.add_file = function(self, path, content)
            self.knowledge_base[path] = content
            self.file_states[path] = "READ"
            self.global_access_counter = self.global_access_counter + 1
            self.file_access_rank[path] = self.global_access_counter
        end
        ctx.touch_file = function(self, path)
            if self.knowledge_base[path] then
                self.global_access_counter = self.global_access_counter + 1
                self.file_access_rank[path] = self.global_access_counter
            end
        end
        ctx.track_requested_file = function(self, path)
            if path then self.turn_requested_files[path] = true end
        end
        ctx.pin_file = function(self, path)
            if self.knowledge_base[path] then self.pinned_files[path] = true; return true end
            return false
        end
        ctx.get_file_context = function(self, file_info)
            local content = self.knowledge_base[file_info.path]
            if not content then return "" end
            return string.format("\n<file_context path=\"%s\" status=\"READ_ONLY\">\n\n%s\n\n</file_context>\n",
                file_info.path, content)
        end
        ctx.estimate_tokens = function(self, text, _)
            return math.ceil(#tostring(text) / 3.5)
        end
        return ctx
    end
    -- =========================================================================
    -- STEP 1: read_file cache-hit re-injects content
    -- =========================================================================
    describe("read_file cache-hit re-injection", function()
        it("should re-inject file_context XML on cache hit", function()
            -- Clear cached module to get fresh registration
            package.loaded["read_file"] = nil
            local mod = require("read_file")
            local reg = { tools = {} }
            reg.register = function(name, desc, example, handler, _, manifest)
                reg.tools[name] = { handler = handler, manifest = manifest }
            end
            mod.register(reg)
            local handler = reg.tools["read_file"].handler
            assert.is_not_nil(handler, "read_file handler must be registered")
            local ctx = make_mock_ctx({
                knowledge_base = { ["src/main.c"] = "int main() { return 0; }" }
            })
            local result = handler("src/main.c", ctx, "TEST")
            assert.is_not_nil(result.output)
            assert.truthy(result.output:find("<file_context"), "Output must contain <file_context> block")
            assert.truthy(result.output:find('path="src/main.c"'), "Must reference correct path")
            assert.truthy(result.output:find("int main"), "Must contain actual file content")
            assert.truthy(result.output:find("reloaded into visible context"), "Must say reloaded into visible context")
        end)
        it("should still show size hint for large files on cache hit", function()
            package.loaded["read_file"] = nil
            local mod = require("read_file")
            local reg = { tools = {} }
            reg.register = function(name, desc, example, handler, _, manifest)
                reg.tools[name] = { handler = handler, manifest = manifest }
            end
            mod.register(reg)
            local handler = reg.tools["read_file"].handler
            local big_content = string.rep("x", 5000)
            local ctx = make_mock_ctx({
                knowledge_base = { ["big.lua"] = big_content }
            })
            local result = handler("big.lua", ctx, "TEST")
            assert.truthy(result.output:find("read_chunk"), "Should suggest read_chunk for large files")
        end)
    end)
    -- =========================================================================
    -- STEP 2: pin lazy-reload after snapshot restore
    -- =========================================================================
    describe("pin lazy-reload", function()
        it("should re-read from disk when KB is empty but file_states has path", function()
            local utils = require("utils")
            local original_read = utils.read_file_range
            utils.read_file_range = function(path)
                if path == "/tmp/test_project/src/core.h" then
                    return "#define FOO 42"
                end
                return nil, "not found"
            end
            package.loaded["pin"] = nil
            local mod = require("pin")
            local reg = { tools = {} }
            reg.register = function(name, desc, example, handler, _, manifest)
                reg.tools[name] = { handler = handler, manifest = manifest }
            end
            mod.register(reg)
            local handler = reg.tools["pin"].handler
            assert.is_not_nil(handler, "pin handler must be registered")
            local ctx = make_mock_ctx({
                knowledge_base = {},
                file_states = { ["src/core.h"] = "KNOWN" }
            })
            local result = handler("src/core.h", ctx, "TEST")
            assert.truthy(result.output:find("Pinned"), "Should successfully pin after lazy-reload: " .. tostring(result.output))
            assert.is_not_nil(ctx.knowledge_base["src/core.h"], "File should be loaded into KB")
            assert.is_true(ctx.pinned_files["src/core.h"], "File should be marked as pinned")
            utils.read_file_range = original_read
        end)
        it("should fail gracefully if file not on disk either", function()
            local utils = require("utils")
            local original_read = utils.read_file_range
            utils.read_file_range = function(path)
                return nil, "No such file"
            end
            package.loaded["pin"] = nil
            local mod = require("pin")
            local reg = { tools = {} }
            reg.register = function(name, desc, example, handler, _, manifest)
                reg.tools[name] = { handler = handler, manifest = manifest }
            end
            mod.register(reg)
            local handler = reg.tools["pin"].handler
            local ctx = make_mock_ctx({
                knowledge_base = {},
                file_states = { ["ghost.lua"] = "KNOWN" }
            })
            local result = handler("ghost.lua", ctx, "TEST")
            assert.truthy(result.output:find("ERROR"), "Should report error when file not on disk")
            utils.read_file_range = original_read
        end)
    end)
    -- =========================================================================
    -- STEP 3: read_chunk stores FULL file in knowledge_base
    -- =========================================================================
    describe("read_chunk full-file KB storage", function()
        it("should store complete file content in KB, not just the chunk", function()
            local full_file_content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10"
            local utils = require("utils")
            local original_read = utils.read_file_range
            utils.read_file_range = function(path)
                if path == "/tmp/test_project/data.txt" then
                    return full_file_content
                end
                return nil, "not found"
            end
            package.loaded["read_chunk"] = nil
            local mod = require("read_chunk")
            local reg = { tools = {} }
            reg.register = function(name, desc, example, handler, _, manifest)
                reg.tools[name] = { handler = handler, manifest = manifest }
            end
            mod.register(reg)
            local handler = reg.tools["read_chunk"].handler
            assert.is_not_nil(handler, "read_chunk handler must be registered")
            local ctx = make_mock_ctx({})
            local result = handler("data.txt:3-5", ctx, "TEST")
            assert.is_not_nil(result.output)
            assert.truthy(result.output:find("line3"), "Chunk display should show line3")
            assert.truthy(result.output:find("line5"), "Chunk display should show line5")
            -- CRITICAL: KB must have the FULL file, not just lines 3-5
            assert.is_not_nil(ctx.knowledge_base["data.txt"], "Full file must be in KB")
            assert.equals(full_file_content, ctx.knowledge_base["data.txt"],
                "KB must contain the COMPLETE file, not just the requested chunk")
            utils.read_file_range = original_read
        end)
    end)
    -- =========================================================================
    -- STEP 4: builder auto-rehydration for pinned files
    -- =========================================================================
    describe("builder auto-rehydration", function()
        it("should re-read pinned files from disk when KB is empty", function()
            local utils = require("utils")
            local original_read = utils.read_file_range
            utils.read_file_range = function(path)
                if path == "/tmp/test_project/config.yaml" then
                    return "key: value"
                end
                return nil, "not found"
            end
            local ctx = make_mock_ctx({
                knowledge_base = {},
                file_states = { ["config.yaml"] = "KNOWN" },
                pinned_files = { ["config.yaml"] = true }
            })
            local builder = require("context.builder")
            local recency = builder.get_recency_block(ctx, {})
            assert.truthy(recency:find("config.yaml"), "Recency block must contain the rehydrated pinned file")
            assert.truthy(recency:find("key: value"), "Recency block must contain the file content")
            assert.truthy(recency:find('status="PINNED"'), "Should be marked as PINNED")
            utils.read_file_range = original_read
        end)
        it("should NOT re-read if file already in KB", function()
            local read_called = false
            local utils = require("utils")
            local original_read = utils.read_file_range
            utils.read_file_range = function(path)
                read_called = true
                return "from disk"
            end
            local ctx = make_mock_ctx({
                knowledge_base = { ["existing.lua"] = "local x = 1" },
                file_states = { ["existing.lua"] = "READ" },
                pinned_files = { ["existing.lua"] = true }
            })
            local builder = require("context.builder")
            local recency = builder.get_recency_block(ctx, {})
            assert.falsy(read_called, "Should NOT read from disk if file already in KB")
            assert.truthy(recency:find("local x = 1"), "Should use KB content")
            utils.read_file_range = original_read
        end)
    end)
end)
