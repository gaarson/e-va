# Multi-Stage Executor: Fixes & Test Coverage Report
## 1. Applied Fixes (8 issues across 3 files)
### 1.1 `agent/multi_stage.lua`
| # | Fix | Severity | Description |
|---|-----|----------|-------------|
| 1 | Removed `load_state()` recovery block | **CRITICAL** | The block `-- Fix #5: Attempt state recovery at loop start` called `multi_exec:load_state()` AFTER `start_task_with_intent()` had already reset state. This caused stale `.multi_stage_state.json` data to overwrite fresh state on every subsequent multi-stage run, immediately breaking patch/create_file operations. |
| 2 | Removed `save_state_local()`, unified to `multi_exec:save_state()` | MEDIUM | The local function saved a lightweight snapshot with a different schema than `multi_exec:save_state()`. Unified to use the executor's own method for consistent state format. |
### 1.2 `agent/turn.lua`
| # | Fix | Severity | Description |
|---|-----|----------|-------------|
| 3 | Tool-specific `success_criteria` | MEDIUM | Replaced generic template with per-tool criteria: patch (SEARCH/REPLACE match + no PATCH FAILED), create_file (valid syntax + matches goal), delegate_plan (valid JSON + non-empty plan + memo). |
| 4 | `last_user_msg` truncated to 2000 chars | LOW | Prevents context bloat when the last user message is very long (e.g., contains full file dumps). |
| 5 | `has_payload` detection improved | MEDIUM | Added `or args_part:find("=======")` to catch malformed patches that have the separator line but not the full `<<<<<<< SEARCH` marker. |
### 1.3 `multi_stage_executor/executor.lua`
| # | Fix | Severity | Description |
|---|-----|----------|-------------|
| 6 | Log message corrected | LOW | "Skipping review cycle." → "Limiting to 1 iteration (simple task). Review still runs but cannot revise." (was misleading — review DOES run). |
| 7 | Token estimation uses config | LOW | `math.floor(#llm_response / 4)` → `math.floor(#llm_response / (self.ctx.config.LIMITS.CHARS_PER_TOKEN or 3.5))`. The hardcoded `/4` was inaccurate for non-English text. |
| 8 | Duplicate `file_path` guard | MEDIUM | Before prepending `file_path` to `effective_payload`, now checks if payload already starts with it. Prevents double-prepending when the LLM includes the file path in its response. |
---
## 2. Root Cause Analysis
The **critical bug (#1)** was the primary culprit breaking the coder's file operations:
```
Timeline of the bug:
1. First multi-stage run: start_task_with_intent() → fresh state → works fine
2. save_state() writes .multi_stage_state.json
3. Second multi-stage run: start_task_with_intent() → resets state → CORRECT
4. load_state() reads stale .multi_stage_state.json → OVERWRITES fresh state → BROKEN
5. Executor thinks it's in a different state/iteration → immediate error
```
The fix removes step 4 entirely. State recovery should only happen at application startup, not mid-loop.
---
## 3. Test Coverage Report
### Summary
| Module | Files | ~Tests | Coverage Focus |
|--------|-------|--------|----------------|
| `llm_handler` | 3 | ~27 | cqueues, request handling, SSE stream parsing |
| `multi_stage_executor` | 3 | ~95 | Intent/review parsing, state machine, safety guards, manifest integration |
| `patcher` | 1 | ~35 | SEARCH/REPLACE engine, fuzzy matching, performance |
| `loop_guard` | 1 | ~20 | Duplicate/sequence/error loop detection, intervention levels |
| `reasoning` | 1 | ~15 | `<thinking>` tag stripping, streaming assembly, compressor |
| `state_recovery` | 1 | ~25 | Snapshot round-trip, atomic save, backup, corruption handling |
| `ui` (8 files) | 8 | ~160+ | Input handling, command parsing, stream printing, interrupts |
| **TOTAL** | **19** | **~350+** | |
### Key Coverage Gaps Identified
1. **No integration test** for the full `run_multi_stage_loop` with real LLM calls (mocked at LLM boundary only)
2. **No test** for the `load_state()` / `save_state()` round-trip in `multi_stage_executor` (the exact code path that was buggy)
3. **No test** for the `has_payload` detection logic in `agent/turn.lua`
4. **No test** for the `file_path` duplicate-prepending guard (fix #8)
5. **No test** for tool-specific `success_criteria` generation (fix #3)
### Recommended New Tests
```lua
-- Test: load_state does NOT corrupt fresh state after start_task_with_intent
it("start_task_with_intent state is not overwritten by load_state", function()
    local exec = multi_stage.new(ctx, "TEST_AGENT")
    exec:start_task_with_intent("Task", "Ctx", "patch", "Hint", "Criteria", "src/a.lua")
    assert.equals(exec.state, multi_stage.STATES.INTENT_READY)
    -- Simulate what the old buggy code did:
    -- exec:load_state()  -- THIS SHOULD NOT BE CALLED
    -- Verify state is still INTENT_READY
end)
-- Test: file_path not double-prepended
it("file_path not prepended if payload already starts with it", function()
    local exec = multi_stage.new(ctx, "TEST_AGENT")
    exec:start_task_with_intent("Task", "Ctx", "patch", "Hint", "Criteria", "src/a.lua")
    local result = exec:feed_response("src/a.lua\n<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE")
    -- effective_payload should NOT have "src/a.lua" twice
    local count = 0
    for _ in result.payload:gmatch("src/a.lua") do count = count + 1 end
    assert.equals(1, count)
end)
```
---
## 4. Verification
All 3 modified files pass `luac -p` syntax check:
```
$ luac -p agent/multi_stage.lua && luac -p agent/turn.lua && luac -p multi_stage_executor/executor.lua
ALL SYNTAX OK
```
---
*Generated: 2025-07-14*
