local M = {}
-- Module-level state (shared across sub-modules)
M._last_optimization = {
    timestamp = 0,
    context_size = 0,
    result = nil
}
M._OPTIMIZE_THRESHOLD = 0.10
M._last_llm_call_time = 0
M._MIN_CALL_INTERVAL = 2
M._summary_cache = {}
M._summary_cache_max = 100
M._llm_summarization_count = 0
M._llm_summarization_reset_time = 0
M._MAX_SUMMARIES_PER_TURN = 3
M._MIN_MESSAGE_LENGTH = 5000
-- Load sub-modules
local context_analysis = require("optimizer.context_analysis")
local summarization = require("optimizer.summarization")
-- Re-export context_analysis functions
M.get_last_result = context_analysis.get_last_result
M.analyze_and_optimize = context_analysis.analyze_and_optimize
M._do_analyze_and_optimize = context_analysis._do_analyze_and_optimize
M.summarize_unclosed_thought = context_analysis.summarize_unclosed_thought
M.generate_continuation_prompt = context_analysis.generate_continuation_prompt
-- Re-export summarization functions
M.should_summarize_with_llm = summarization.should_summarize_with_llm
M.summarize_message = summarization.summarize_message
M.summarize_conversation_segment = summarization.summarize_conversation_segment
-- Inject shared state into sub-modules
context_analysis._last_optimization = M._last_optimization
context_analysis._last_llm_call_time = M._last_llm_call_time
context_analysis._MIN_CALL_INTERVAL = M._MIN_CALL_INTERVAL
context_analysis._OPTIMIZE_THRESHOLD = M._OPTIMIZE_THRESHOLD
summarization._llm_summarization_count = M._llm_summarization_count
summarization._llm_summarization_reset_time = M._llm_summarization_reset_time
summarization._MAX_SUMMARIES_PER_TURN = M._MAX_SUMMARIES_PER_TURN
summarization._MIN_MESSAGE_LENGTH = M._MIN_MESSAGE_LENGTH
summarization._summary_cache = M._summary_cache
summarization._summary_cache_max = M._summary_cache_max
summarization._last_llm_call_time = M._last_llm_call_time
return M
