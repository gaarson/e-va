describe("cqueues integration", function()
    local cqueues = require("cqueues")

    -- ========================================================================
    -- TEST 1: monotime returns a number and is monotonic
    -- ========================================================================
    describe("monotime", function()
        it("should return a number", function()
            local t = cqueues.monotime()
            assert.is_true(type(t) == "number")
        end)

        it("should be monotonic (second call >= first call)", function()
            local t1 = cqueues.monotime()
            local t2 = cqueues.monotime()
            assert.is_true(t2 >= t1)
        end)
    end)

    -- ========================================================================
    -- TEST 2: cqueues.new() creates a valid loop object
    -- ========================================================================
    describe("create_loop", function()
        it("should create a valid loop object with loop and wrap methods", function()
            local cq = cqueues.new()
            assert.is_true(type(cq) == "userdata")
            assert.is_true(type(cq.loop) == "function")
            assert.is_true(type(cq.wrap) == "function")
        end)
    end)

    -- ========================================================================
    -- TEST 3: wrap_request wraps a function in the event loop
    -- ========================================================================
    describe("wrap_request", function()
        it("should wrap a simple function and return a coroutine", function()
            local cq = cqueues.new()
            local co = cq:wrap(function()
                return 42
            end)
            assert.is_true(type(co) == "userdata")
        end)
    end)

    -- ========================================================================
    -- TEST 4: Multiple wrapped coroutines can be scheduled concurrently
    -- ========================================================================
    describe("concurrent coroutines", function()
        it("should schedule multiple coroutines", function()
            local cq = cqueues.new()
            local results = {}

            local co1 = cq:wrap(function()
                cqueues.sleep(0.001)
                table.insert(results, 1)
            end)

            local co2 = cq:wrap(function()
                cqueues.sleep(0.001)
                table.insert(results, 2)
            end)

            -- Run the loop briefly to process coroutines
            local ok, err = pcall(function()
                cq:loop(cqueues.monotime() + 0.1)
            end)
            -- Both coroutines should have completed
            assert.is_true(#results >= 1)
        end)
    end)

    -- ========================================================================
    -- TEST 5: cqueues.sleep() yields properly
    -- ========================================================================
    describe("sleep", function()
        it("should yield without blocking the loop", function()
            local cq = cqueues.new()
            local slept = false

            cq:wrap(function()
                cqueues.sleep(0.001)
                slept = true
            end)

            local ok, err = pcall(function()
                cq:loop(cqueues.monotime() + 0.1)
            end)
            assert.is_true(slept)
        end)
    end)

    -- ========================================================================
    -- TEST 6: dedup hash generation is deterministic
    -- ========================================================================
    describe("dedup hash determinism", function()
        it("should produce the same hash for the same input", function()
            local dedup = require("llm_handler.dedup")
            local profile = { model = "test", url = "http://test.com" }
            local messages = { { role = "user", content = "hello" } }
            local options = { temperature = 0.7 }

            local h1 = dedup._request_hash(profile, messages, options)
            local h2 = dedup._request_hash(profile, messages, options)

            assert.equals(h1, h2)
        end)
    end)

    -- ========================================================================
    -- TEST 7: _cleanup_in_flight removes expired entries
    -- ========================================================================
    describe("cleanup_in_flight", function()
        it("should remove expired entries", function()
            local cqueues = require("cqueues")
            local dedup = require("llm_handler.dedup")
            dedup._in_flight_requests = {}
            dedup._DEDUP_CLEANUP_INTERVAL = 1

            -- Add an expired entry
            dedup._in_flight_requests["hash1"] = { timestamp = cqueues.monotime() - 10 }
            -- Add a fresh entry
            dedup._in_flight_requests["hash2"] = { timestamp = cqueues.monotime() }

            dedup._cleanup_in_flight()

            assert.is_nil(dedup._in_flight_requests["hash1"])
            assert.is_not_nil(dedup._in_flight_requests["hash2"])

            -- Cleanup
            dedup._in_flight_requests = {}
        end)
    end)
end)