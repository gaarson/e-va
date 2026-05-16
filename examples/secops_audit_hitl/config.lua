local os = require("os")

return {
    AGENTS = {
        SEC_AUDITOR = {
            name = "SEC_AUDITOR",
            prompt_file = "prompts/auditor.md",
            allowed_tools = { "explore_tree", "outline", "search", "read_file", "read_chunk", "delegate_plan" }
        },
        SEC_PATCHER = {
            name = "SEC_PATCHER",
            prompt_file = "prompts/patcher.md",
            allowed_tools = { "patch", "shell", "read_file", "task_complete" }
        }
    },
    PIPELINE = {
        { stage = "VULN_DISCOVERY", agents = { "SEC_AUDITOR" }, mode = "sequential" },
        { stage = "HUMAN_APPROVAL", agents = { "SEC_AUDITOR" }, mode = "interactive" },
        { stage = "REMEDIATION", agents = { "SEC_PATCHER" }, mode = "sequential" }
    },
    TASKS = {
        { file = ".", instruction = "Audit the controllers/ directory for SQL Injection vulnerabilities.", max_turns = 15 }
    }
}
