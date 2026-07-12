-- context/config.lua

-- Configuration constants, defaults, and model profile merging.


local M = {}

local utils = require("utils")


M.DEFAULT_CONFIG = {

    storage = {

        max_history_messages = 200,

        max_history_tokens = 160000,

        squash_threshold_messages = 150,

        squash_threshold_tokens = 50000,

        dedup_tool_outputs = true,

        include_pinned_in_recency = true,

        max_recent_tool_outputs = 5,

    },

    context_injection = {

        mode = "append_to_last_user",

        recency_block_enabled = true,

        search_digest_enabled = true,

        max_recency_tokens = 4000,

        max_search_digest_tokens = 2000,

        stale_threshold_turns = 10,

    },

    command_flow = {

        strict_parsing = true,

        max_retries = 3,

        auto_squash_on_mutation = true,

        continuation_prompt = "ok",

        reinforcement_interval = 5,

        allow_consecutive_assistant = false,

    },

    token_estimation = {

        chars_per_token = 3.5,

        system_prompt_estimate = 6000,

        reserved_output = 5000,

    },

    compression = {

        enabled = true,

        zone1_size = 10,

        zone2_size = 20,

        max_tool_output_bytes = 2048,

        compress_thinking_blocks = true,

        preserve_errors = true,

        llm_summarization = {

            enabled = true,

            min_message_length = 5000,

            rate_limit_seconds = 30,

            max_summaries_per_turn = 3,

        },

    },

    model_profiles = {

        reasoning = {

            context_injection = { mode = "separate_message" },

            command_flow = { strict_parsing = true, max_retries = 5 },

            storage = { squash_threshold_tokens = 100000 }

        },

        coding = {

            context_injection = { mode = "append_to_last_user", max_recency_tokens = 6000 },

            command_flow = { auto_squash_on_mutation = true, reinforcement_interval = 3 },

            storage = { max_history_tokens = 120000 }

        },

        chat = {

            context_injection = { recency_block_enabled = false, search_digest_enabled = false },

            command_flow = { strict_parsing = false, max_retries = 2 },

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