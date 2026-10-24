-- context/config.lua
-- Configuration constants, defaults, and model profile merging.
local M = {}
local utils = require("utils")
M.DEFAULT_CONFIG = {
    storage = {
        max_history_messages = 200,
        max_history_tokens = 160000,
        include_pinned_in_recency = true,
    },
    context_injection = {
        mode = "stable_append",
        recency_block_enabled = true,
        search_digest_enabled = true,
        max_recency_tokens = 4000,
        max_search_digest_tokens = 2000,
    },
    command_flow = {
        max_retries = 3,
        auto_squash_on_mutation = true,
        continuation_prompt = "ok",
        dedup_exceptions = { "task_complete*", "delegate_plan*", "shell*", "mcp_browser_*", "search*", "read_file*", "read_chunk*" },
    },
    token_estimation = {
        chars_per_token = 3.5,
        system_prompt_estimate = 6000,
        reserved_output = 5000,
    },

    model_profiles = {
        reasoning = {
            context_injection = { mode = "separate_message" },
            command_flow = { max_retries = 5 },
        },
        coding = {
            context_injection = { mode = "stable_append", max_recency_tokens = 6000 },
            command_flow = { auto_squash_on_mutation = true },
            storage = { max_history_tokens = 120000 }
        },
        chat = {
            context_injection = { recency_block_enabled = false, search_digest_enabled = false },
            command_flow = { max_retries = 2 },
            storage = { max_history_messages = 50, max_history_tokens = 40000 }
        }
    }
}
M.IMPORTANCE_SCORES = {
    TASK_DESCRIPTION = 100,
    USER_QUESTION = 80,
    ASSISTANT_REASONING = 40,
    TOOL_OUTPUT = 20,
    SQUASHED_MUTATION = 5,
}
function M.apply_model_profile(flow_config, profile_name)
    if not profile_name or not flow_config.model_profiles[profile_name] then
        return flow_config
    end
    return utils.deep_merge(flow_config, flow_config.model_profiles[profile_name])
end
return M