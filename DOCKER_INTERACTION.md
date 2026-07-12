# E-va Agent — Docker Interaction Reference

## 1. Architecture Overview

### Container Layout
The E-va Docker container follows a strict separation of concerns:

| Path | Purpose |
|------|---------|
| `/opt/e-va` | Agent binaries, Lua modules, and core framework (immutable) |
| `/workspace` | Project root directory for user code (mounted volume) |
| `/workspace/.e-va-conf` | Persistent configuration directory |

### Init System
The container uses `tini` as PID 1 for proper signal handling and zombie process reaping. This ensures graceful shutdown and prevents orphaned processes.

### User Model
- Runs as unprivileged user `chromeuser` by default
- Chrome is wrapped with `--no-sandbox` flag for container compatibility
- `sudo` is available for `chromeuser` (NOPASSWD) — use cautiously

### Entrypoint Chain
```
tini → /opt/e-va/e-va (bash) → lua agent.lua
```

## 2. Building the Image

### Standard Build
```bash
docker build -t e-va-agent .
```

### Build Process Details
During the build, the following components are installed:
- **System packages**: `apt` packages for development tools
- **Chrome**: Google Chrome stable with `--no-sandbox` wrapper
- **LuaRocks modules**: `luasocket`, `inspect`, `lua-cjson`
- **C extensions**: Compiled via `make` (includes `patcher_core.so`)
- **npm global**: `chrome-devtools-mcp` for browser automation

### .dockerignore Implications
The `.dockerignore` file excludes:
- `.git/` directories
- `node_modules/`
- Build artifacts
- Large binary files
- `.e-va-conf/` (to prevent baking configurations into images)

## 3. Volume Mounting Strategies

### 3.1 Basic Project Mount
```bash
docker run -v $(pwd):/workspace e-va-agent
```

### 3.2 Persistent Configuration
```bash
-v $(pwd)/.e-va-conf:/workspace/.e-va-conf
```

This mount is critical for:
- `config.lua` overrides
- `state.json` persistence across sessions
- `custom_tools.lua` for extended functionality
- `prompts/` directory for custom agent instructions

### 3.3 Recommended Full Mount
```bash
docker run --rm -it \
  -v $(pwd):/workspace \
  -v $(pwd)/.e-va-conf:/workspace/.e-va-conf \
  e-va-agent
```

## 4. Environment Variables (Complete Reference)

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_HOME` | `/opt/e-va` | Path to agent binaries and Lua modules |
| `PROJECT_ROOT` | `/workspace` | Working directory for projects |
| `LLM_URL` | `http://localhost:8000/v1/chat/completions` | LLM API endpoint |
| `LLM_MODEL` | (none) | Model identifier |
| `GIT_EVA_URL` | (none) | If set, clones this repo into `/app` on startup |
| `CHROME_PATH` | `/usr/bin/google-chrome-stable` | Chrome binary path |
| `ENV_PATH` | auto-detected | Path to `.env` file (checked in `PROJECT_ROOT` then `AGENT_HOME`) |

### Passing Environment Variables
```bash
docker run -e LLM_URL=http://your-api:8080/v1/chat/completions e-va-agent
```

## 5. Execution Modes

### 5.1 Pipe Mode (Default — Programmatic/API)
Default CMD: `--pipe .`

#### Basic Usage
```bash
echo "Analyze this code" | docker run -i e-va-agent
```

#### Interactive Pipe Mode
```bash
docker run -it e-va-agent
```

#### Pipe Protocol Specification
- **Startup marker**: `=== PIPE MODE START ===`
- **Prompt on stderr**: `> `
- **Input**: Line-by-line via stdin
- **Response markers**: `=== RESPONSE START ===` ... `=== RESPONSE END ===`
- **Termination**: Send `quit` or `exit` via stdin
- **Exit marker**: `=== PIPE MODE EXIT ===`
- **Empty lines**: Ignored
- **Each input**: Triggers a full pipeline execution

### 5.2 Interactive TUI Mode
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va
```

#### With a Specific Task
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va src/main.c "Fix the bug"
```

#### HITL (Human-in-the-Loop) Commands
| Command | Function |
|---------|----------|
| `/go` | Advance to next pipeline stage |
| `/back` | Return to previous stage |
| `/mode <stage_name>` | Jump to specific stage by name |
| `/exit` | Abort execution |
| Regular text | Sent as user message to current agent |

**Auto-loop Behavior**: Agent continues executing commands automatically (up to 10 iterations)
**Interruption Handling**: If generation is interrupted, user can provide corrections (up to 3 retries)

### 5.3 Bootstrap Mode
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va --bootstrap
```

#### With Context
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va --bootstrap "This is a Python web app"
```

#### Bootstrap Process
1. Creates `.e-va-conf/` directory structure
2. Scans project AST via `explore_tree`
3. Detects project type (Node.js, Rust, Go, Makefile)
4. Generates `config.lua` with optimal PIPELINE and token limits
5. Creates Markdown prompts in `.e-va-conf/prompts/`
6. **Requires**: `LLM_URL` and `LLM_MODEL` to be set

### 5.4 Direct Task Execution
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va src/main.c "Fix memory leak"
```

#### Without File (Global Scope)
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va "Refactor the authentication module"
```

### 5.5 Agent Override Mode
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va --agent CODER "Refactor function X"
```

This bypasses the full pipeline and runs only the specified agent.

### 5.6 Batch Task Processing
Tasks defined in `.e-va-conf/config.lua` under `TASKS` array:
```lua
TASKS = {
  { file = "src/main.c", instruction = "Fix bug", max_turns = 10 },
  { instruction = "Add logging", max_turns = 5 }
}
```

Run with:
```bash
docker run -it -v $(pwd):/workspace e-va-agent ./e-va
```

## 6. Configuration System

### 6.1 Config Loading Order
1. Base config: `/opt/e-va/config.lua` (immutable, baked into image)
2. Local overrides: `/workspace/.e-va-conf/config.lua` (deep merged)
3. Environment variables override specific fields

### 6.2 Key Config Sections
| Section | Purpose |
|---------|---------|
| `PIPELINE` | Array of stages with agents and modes (sequential/interactive/parallel) |
| `AGENTS` | Per-agent configuration (URL, model, temperature, allowed_tools, prompt_file) |
| `LIMITS` | `MAX_CONTEXT`, `RESERVED_OUTPUT`, `SYSTEM_PROMPT_ESTIMATE` |
| `CONTEXT_FLOW` | Context management settings |
| `HANDOFF` | Inter-agent handoff configuration |
| `PIPELINE_SETTINGS` | `MAX_TURNS`, `ABORT_ON_FATAL` |

### 6.3 Custom Tools
Place in `.e-va-conf/custom_tools.lua`:
```lua
return function(registry, utils, Context)
  registry.register("my_tool", "Description", "example", function(args, ctx, agent)
    return { output = "result" }
  end)
end
```

## 7. State Persistence

### 7.1 State File
**Location**: `/workspace/.e-va-conf/.state.json`
- Automatically saved after each agent turn
- Restored on container restart (continuation)
- Deleted when pipeline completes successfully

### 7.2 Task File
**Location**: `/workspace/.e-va-conf/task.txt`
- If no instruction is provided via CLI, this file is read
- Useful for pre-populating tasks outside the container

## 8. Browser & MCP Integration

### 8.1 Chrome Setup
- Chrome installed with `--no-sandbox` wrapper for container compatibility
- Wrapper script at `/usr/bin/google-chrome-stable` adds required flags automatically

### 8.2 MCP (Model Context Protocol)
- `chrome-devtools-mcp` installed globally via npm
- Agents can use `mcp_browser_*` tools if configured in `config.lua`
- Available tools: `navigate`, `screenshot`, `click`, `fill`, `evaluate_script`, etc.

## 9. Networking

### 9.1 LLM API Access
The container must reach the LLM API endpoint. Options:
- **Host network**: `--network host`
- **Port mapping**: Ensure LLM server is accessible from container
- **DNS**: Container inherits host DNS resolution

### 10.2 Git Clone on Startup
```bash
docker run -e GIT_EVA_URL=https://github.com/user/repo.git e-va-agent
```
Clones the repo into `/app` on startup.

## 11. Logging
- Logs written to `/workspace/logs/`
- Prompt logs: `{agent}_PROMPT.json` per turn
- Message logs: Formatted conversation history
- Controlled by `logger.lua` module

## 12. Troubleshooting

### 12.1 Common Issues
| Problem | Solution |
|---------|----------|
| `FATAL: No LLM URL found` | Set `LLM_URL` env var or configure in `config.lua` |
| `FATAL: No LLM Model found` | Set `LLM_MODEL` env var |
| Chrome crashes | Verify `--no-sandbox` wrapper is intact |
| Permission denied on workspace | Ensure mounted directory is readable by `chromeuser` |
| Max turns reached | Increase `PIPELINE_SETTINGS.MAX_TURNS` in config |
| Context overflow | Reduce `LIMITS.MAX_CONTEXT` or add `context_optimizer` calls |

### 12.2 Debugging Tips
- Run with `--entrypoint bash` to inspect container:
  ```bash
  docker run -it --entrypoint bash e-va-agent
  ```
- Check logs: `docker logs <container_id>`
- Inspect state: `cat /workspace/.e-va-conf/.state.json`
- Test LLM connectivity: `curl $LLM_URL` from within container

## 13. Security Considerations
- Container runs as unprivileged `chromeuser` by default
- `sudo` is available for `chromeuser` (NOPASSWD) — use cautiously
- Shell commands from agents are escaped via `utils.shell_quote`
- Shell Circuit Breaker: 3 consecutive build failures abort the loop
- Never run with `--privileged` unless absolutely necessary

## 14. Complete Usage Examples

### Quick Start
```bash
docker run --rm -it \
  -v $(pwd):/workspace \
  -e LLM_URL=http://host.docker.internal:8000/v1/chat/completions \
  -e LLM_MODEL=qwen2.5-coder \
  e-va-agent ./e-va --bootstrap
```

### CI/CD Pipe Mode
```bash
echo "Review pull request changes" | \
  docker run -i --rm \
  -v $(pwd):/workspace \
  -e LLM_URL=$LLM_API_URL \
  -e LLM_MODEL=$MODEL_NAME \
  e-va-agent
```

### Full Featured Development Session
```bash
docker run --rm -it \
  -v $(pwd):/workspace \
  -v $(pwd)/.e-va-conf:/workspace/.e-va-conf \
  -e LLM_URL=http://localhost:8000/v1/chat/completions \
  -e LLM_MODEL=mistral-nemo \
  --memory 8g \
  --cpus 4 \
  e-va-agent ./e-va src/app.py "Implement async database layer"
```
