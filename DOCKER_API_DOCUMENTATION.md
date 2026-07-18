# E-va Docker Agent — Programmatic API Documentation
This document covers everything needed to interact with the E-va autonomous agent container programmatically.
---
## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Quick Start](#2-quick-start)
3. [Pipe Mode Protocol](#3-pipe-mode-protocol)
4. [Docker Run Reference](#4-docker-run-reference)
5. [Environment Variables](#5-environment-variables)
6. [Volume Mounts](#6-volume-mounts)
7. [Programmatic Examples](#7-programmatic-examples)
8. [Healthcheck & Lifecycle](#8-healthcheck--lifecycle)
9. [Security Model](#9-security-model)
10. [Known Limitations](#10-known-limitations)
11. [Troubleshooting](#11-troubleshooting)
---
## 1. Architecture Overview
E-va is a multi-agent Lua-based system packaged in a Debian Trixie Docker container. It consists of:
| Component | Description |
|-----------|-------------|
| **ARCHITECT** | Planning agent — analyzes codebases, creates execution plans, delegates tasks |
| **CODER** | Implementation agent — executes patches, creates files, verifies with shell commands |
| **Pipeline Engine** | Orchestrates stages: `ANALYSIS_AND_PLANNING` → `REVIEW_AND_CHAT` → `IMPLEMENTATION` |
| **ContextFlow** | Token-aware context manager with compression, deduplication, and handoff memos |
| **Chrome DevTools MCP** | Browser automation via `chrome-devtools-mcp` |
| **C Extensions** | `patcher_core.so` (file patching) and `ipc_mcp.so` (IPC/MCP bridge) |
### Container Layout
```
/opt/e-va/              # Agent home (read-only for chromeuser)
├── e-va                # Entry-point bash script
├── agent.lua           # Entry point (requires agent/init.lua)
├── config.lua          # Default configuration
├── patcher_core.so     # C extension: file patching
├── ipc_mcp.so          # C extension: IPC/MCP bridge
├── prompts/            # System prompts (architect.md, coder.md)
└── lua_modules/        # Luarocks dependencies
/workspace/             # Project workspace (writable, VOLUME)
├── .e-va-conf/         # Per-project config overrides (VOLUME)
│   ├── config.lua      # Optional: overrides default config
│   ├── task.txt        # Optional: task instruction file
│   └── pictures/       # Screenshots/images
└──                     # Your project files
```
---
## 2. Quick Start
### Basic Interactive Session
```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  -e LLM_URL="http://your-llm:8000/v1/chat/completions" \
  -e LLM_MODEL="your-model" \
  e-va-agent ./e-va --pipe
```
### One-Shot Task
```bash
echo "Analyze the codebase and create a summary" | \
docker run -i --rm \
  -v $(pwd):/workspace \
  -e LLM_URL="http://your-llm:8000/v1/chat/completions" \
  -e LLM_MODEL="your-model" \
  e-va-agent ./e-va --pipe
```
### With Persistent State
```bash
docker run -d --name eva-session \
  -v $(pwd):/workspace \
  -v $(pwd)/.e-va-conf:/workspace/.e-va-conf \
  -e LLM_URL="http://your-llm:8000/v1/chat/completions" \
  -e LLM_MODEL="your-model" \
  e-va-agent ./e-va --pipe
```
---
## 3. Pipe Mode Protocol
Pipe mode (`--pipe`) is the primary programmatic interface. It operates as a **line-based stdin/stdout protocol**.
### Protocol Specification
| Direction | Format | Description |
|-----------|--------|-------------|
| **Input (stdin)** | One task per line | Each non-empty line triggers a full agent pipeline |
| **Output (stdout)** | Free-form text | Agent responses, tool outputs, and status markers |
| **Termination** | Line containing `quit` or `exit` | Gracefully stops the agent loop |
### Output Markers
The agent emits structured markers you can parse:
```
=== PIPE MODE START ===
=== RESPONSE START ===
<... agent output, tool results, streaming text ...>
=== RESPONSE END ===
<... next response ...>
=== PIPE MODE EXIT ===
```
### Protocol Flow
```
Client                          Docker Container
  |                                  |
  |--- "Analyze src/main.c" -------->|  (stdin line)
  |                                  |
  |<-- === PIPE MODE START === ------|
  |<-- === RESPONSE START === -------|
  |<-- [Agent streaming output] -----|
  |<-- === RESPONSE END === ---------|
  |                                  |
  |--- "Fix the bug in line 42" ---->|  (stdin line)
  |                                  |
  |<-- === RESPONSE START === -------|
  |<-- [Agent streaming output] -----|
  |<-- === RESPONSE END === ---------|
  |                                  |
  |--- "quit" ---------------------->|  (stdin line)
  |<-- === PIPE MODE EXIT === -------|
  |                                  |
```
### Important Notes
- **Each line triggers a FULL pipeline**: ANALYSIS → REVIEW → IMPLEMENTATION. This is not a lightweight chat — each task goes through the complete multi-agent workflow.
- **State persists within a container**: The agent saves state to `/workspace/.e-va-conf/state.json` between turns. Keep the container running for continuity.
- **Empty lines are ignored**: Only non-empty, non-whitespace lines trigger tasks.
- **No JSON protocol**: Input is plain text. The agent parses natural language instructions.
---
## 4. Docker Run Reference
### Full Command Template
```bash
docker run [OPTIONS] \
  -v <host_project_dir>:/workspace \
  -v <host_conf_dir>:/workspace/.e-va-conf \
  -e LLM_URL="<endpoint>" \
  -e LLM_MODEL="<model_id>" \
  --memory <limit> \
  --cpus <count> \
  e-va-agent ./e-va [ARGS]
```
### Docker Options
| Option | Purpose | Example |
|--------|---------|---------|
| `-it` | Interactive TTY (for manual use) | `-it` |
| `-i` | Stdin only (for piping) | `-i` |
| `-d` | Detached mode (background) | `-d` |
| `--name` | Container name | `--name eva-worker` |
| `--rm` | Auto-remove on exit | `--rm` |
| `--memory` | Memory limit | `--memory 4g` |
| `--cpus` | CPU limit | `--cpus 2` |
| `--network` | Network mode | `--network host` |
| `--restart` | Restart policy | `--restart unless-stopped` |
### Volume Mounts
| Mount | Purpose | Required |
|-------|---------|----------|
| `<dir>:/workspace` | Project files (read/write) | **Yes** |
| `<dir>:/workspace/.e-va-conf` | Config, state, task files | Recommended |
| `<dir>:/opt/e-va/logs` | Agent logs (persistent) | Optional |
### Agent Arguments
| Argument | Description |
|----------|-------------|
| `--pipe` | Enable stdin/stdout pipe mode (default in Docker) |
| `--bootstrap` | Run bootstrap mode (initial setup) |
| `--agent <NAME>` | Direct execution with specific agent (ARCHITECT or CODER) |
| `<file> "<instruction>"` | Single-task mode: target file + instruction |
| `--version` / `-v` | Print version and exit |
### Examples
#### Background Worker with Resource Limits
```bash
docker run -d --name eva-worker \
  --memory 8g --cpus 4 \
  --restart unless-stopped \
  -v /home/user/project:/workspace \
  -v /home/user/project/.e-va-conf:/workspace/.e-va-conf \
  -e LLM_URL="http://192.168.1.100:8000/v1/chat/completions" \
  -e LLM_MODEL="Qwen3.5-27B-AWQ" \
  e-va-agent ./e-va --pipe
```
Send tasks:
```bash
docker exec eva-worker sh -c 'echo "Refactor the auth module" | lua /opt/e-va/agent.lua --pipe'
```
#### Direct CODER Execution (Skip Planning)
```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  -e LLM_URL="http://your-llm:8000/v1/chat/completions" \
  -e LLM_MODEL="your-model" \
  e-va-agent ./e-va --agent CODER "Fix the null pointer in parser.c"
```
#### Using task.txt for Complex Instructions
```bash
# Write your task to task.txt
cat > .e-va-conf/task.txt << 'EOF'
Implement a REST API endpoint for user authentication.
Requirements:
1. POST /auth/login accepting email and password
2. JWT token generation with 24h expiry
3. Rate limiting: 5 attempts per minute per IP
4. Return 401 on invalid credentials
EOF
# Run the agent
docker run -it --rm \
  -v $(pwd):/workspace \
  -v $(pwd)/.e-va-conf:/workspace/.e-va-conf \
  -e LLM_URL="http://your-llm:8000/v1/chat/completions" \
  -e LLM_MODEL="your-model" \
  e-va-agent ./e-va --pipe
```
---
## 5. Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_URL` | `http://localhost:8000/v1/chat/completions` | LLM endpoint URL (OpenAI-compatible) |
| `LLM_MODEL` | `default-model` | Model identifier |
| `AGENT_HOME` | `/opt/e-va` | Agent installation directory (read-only) |
| `PROJECT_ROOT` | `/workspace` | Project working directory (read/write) |
| `CHROME_PATH` | `/usr/bin/google-chrome-stable` | Chrome binary path for browser automation |
| `ENV_PATH` | Auto-detected | Path to `.env` file (checked in PROJECT_ROOT then AGENT_HOME) |
| `GIT_EVA_URL` | *(unset)* | If set, clones this repo into workspace on startup |
### LLM Configuration via `.env`
Create a `.env` file in your project root or `.e-va-conf/`:
```bash
# .env
LLM_URL=http://your-llm-server:8000/v1/chat/completions
LLM_MODEL=Qwen3.5-27B-AWQ
```
### Overriding Agent Configuration
Create `.e-va-conf/config.lua` to override defaults:
```lua
-- .e-va-conf/config.lua
local base = require("config").get()
-- Override LLM settings for all agents
base.AGENT_DEFAULTS.url = "http://my-llm:8000/v1/chat/completions"
base.AGENT_DEFAULTS.model = "my-custom-model"
-- Increase context window
base.LIMITS.MAX_CONTEXT = 300000
-- Add custom tasks
base.TASKS = {
    { file = "src/main.c", instruction = "Add logging to all functions" },
    { file = "src/parser.c", instruction = "Fix memory leaks" },
}
return base
```
---
## 6. Volume Mounts
### `/workspace` — Project Directory
- **Purpose**: Contains your project files. The agent reads, writes, and modifies files here.
- **Permissions**: Owned by `chromeuser` (UID 1000). Writable.
- **Recommendation**: Mount your entire project directory here.
```bash
-v /path/to/my-project:/workspace
```
### `/workspace/.e-va-conf` — Configuration & State
- **Purpose**: Stores per-project configuration, state snapshots, task files, and images.
- **Key files**:
  - `config.lua` — Optional config overrides
  - `task.txt` — Task instruction file (read if no CLI instruction provided)
  - `state.json` — Session state (auto-saved between turns)
  - `pictures/` — Screenshots and images for vision models
- **Recommendation**: Mount separately for persistence across container restarts.
```bash
-v /path/to/my-project/.e-va-conf:/workspace/.e-va-conf
```
### `/opt/e-va/logs` — Agent Logs
- **Purpose**: Persistent log storage.
- **Default**: Created at build time, owned by `chromeuser`.
```bash
-v /path/to/logs:/opt/e-va/logs
```
---
## 7. Programmatic Examples
### Python — Pipe Mode Client
```python
import subprocess
import threading
import time
class EvaClient:
    def __init__(self, llm_url, llm_model, project_dir):
        self.proc = subprocess.Popen(
            [
                "docker", "run", "-i", "--rm",
                "-v", f"{project_dir}:/workspace",
                "-e", f"LLM_URL={llm_url}",
                "-e", f"LLM_MODEL={llm_model}",
                "e-va-agent", "./e-va", "--pipe"
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1
        )
        self._stop_event = threading.Event()
        self._reader_thread = threading.Thread(target=self._read_output, daemon=True)
        self._reader_thread.start()
    def _read_output(self):
        """Read stdout in a background thread."""
        buffer = ""
        for line in iter(self.proc.stdout.readline, ""):
            buffer += line
            if "=== RESPONSE END ===" in line:
                # Complete response received
                self._on_response(buffer)
                buffer = ""
    def _on_response(self, response_text):
        """Override this method to handle responses."""
        print(f"[EVA RESPONSE]\n{response_text}\n{'-'*40}")
    def send_task(self, instruction: str) -> None:
        """Send a task instruction to the agent."""
        self.proc.stdin.write(instruction + "\n")
        self.proc.stdin.flush()
    def close(self):
        """Gracefully shut down the agent."""
        self.proc.stdin.write("quit\n")
        self.proc.stdin.flush()
        self.proc.wait(timeout=30)
# Usage
client = EvaClient(
    llm_url="http://localhost:8000/v1/chat/completions",
    llm_model="Qwen3.5-27B-AWQ",
    project_dir="/home/user/my-project"
)
client.send_task("Analyze the codebase structure and identify potential bugs")
time.sleep(5)  # Wait for response
client.send_task("Fix the identified bugs")
time.sleep(10)
client.close()
```
### Python — Async Streaming Client
```python
import asyncio
import asyncio.subprocess as asp
async def run_eva_task(llm_url: str, llm_model: str, project_dir: str, task: str):
    """Run a single task and collect the full response."""
    proc = await asp.create_subprocess_exec(
        "docker", "run", "-i", "--rm",
        "-v", f"{project_dir}:/workspace",
        "-e", f"LLM_URL={llm_url}",
        "-e", f"LLM_MODEL={llm_model}",
        "e-va-agent", "./e-va", "--pipe",
        stdin=asp.PIPE,
        stdout=asp.PIPE,
        stderr=asp.PIPE
    )
    # Send task and quit
    input_data = f"{task}\nquit\n".encode()
    stdout, stderr = await proc.communicate(input=input_data)
    return stdout.decode(), stderr.decode()
async def main():
    stdout, stderr = await run_eva_task(
        llm_url="http://localhost:8000/v1/chat/completions",
        llm_model="Qwen3.5-27B-AWQ",
        project_dir="/home/user/my-project",
        task="Refactor the database connection pool"
    )
    print(stdout)
asyncio.run(main())
```
### Bash — Pipe Mode Script
```bash
#!/bin/bash
# eva_batch.sh — Send multiple tasks to E-va
LLM_URL="${LLM_URL:-http://localhost:8000/v1/chat/completions}"
LLM_MODEL="${LLM_MODEL:-Qwen3.5-27B-AWQ}"
PROJECT_DIR="${1:-.}"
# Start agent in background
docker run -d --name eva-batch \
  -v "$PROJECT_DIR:/workspace" \
  -e "LLM_URL=$LLM_URL" \
  -e "LLM_MODEL=$LLM_MODEL" \
  e-va-agent ./e-va --pipe &
CONTAINER_ID=$!
# Send tasks
send_task() {
    echo "$1" | docker exec -i eva-batch lua /opt/e-va/agent.lua --pipe
}
send_task "Analyze the project structure"
sleep 5
send_task "Create unit tests for src/utils.lua"
sleep 10
send_task "Optimize the database queries in src/db.lua"
sleep 10
# Cleanup
docker stop eva-batch
docker rm eva-batch
```
### Bash — One-Shot Task
```bash
#!/bin/bash
# eva_one_shot.sh — Send a single task and capture output
LLM_URL="${LLM_URL:-http://localhost:8000/v1/chat/completions}"
LLM_MODEL="${LLM_MODEL:-Qwen3.5-27B-AWQ}"
PROJECT_DIR="${1:-.}"
TASK="${2:-'Analyze the codebase'}"
output=$(echo -e "$TASK\nquit" | docker run -i --rm \
  -v "$PROJECT_DIR:/workspace" \
  -e "LLM_URL=$LLM_URL" \
  -e "LLM_MODEL=$LLM_MODEL" \
  e-va-agent ./e-va --pipe 2>&1)
echo "$output"
```
### Node.js — Pipe Mode Client
```javascript
const { spawn } = require('child_process');
class EvaClient {
  constructor(llmUrl, llmModel, projectDir) {
    this.proc = spawn('docker', [
      'run', '-i', '--rm',
      '-v', `${projectDir}:/workspace`,
      '-e', `LLM_URL=${llmUrl}`,
      '-e', `LLM_MODEL=${llmModel}`,
      'e-va-agent', './e-va', '--pipe'
    ]);
    this.outputBuffer = '';
    this.responseCallback = null;
    this.proc.stdout.on('data', (data) => {
      this.outputBuffer += data.toString();
      if (this.outputBuffer.includes('=== RESPONSE END ===')) {
        if (this.responseCallback) {
          this.responseCallback(this.outputBuffer);
        }
        this.outputBuffer = '';
      }
    });
    this.proc.stderr.on('data', (data) => {
      process.stderr.write(data);
    });
  }
  sendTask(instruction, callback) {
    this.responseCallback = callback;
    this.proc.stdin.write(`${instruction}\n`);
  }
  close() {
    this.proc.stdin.write('quit\n');
    this.proc.stdin.end();
  }
}
// Usage
const client = new EvaClient(
  'http://localhost:8000/v1/chat/completions',
  'Qwen3.5-27B-AWQ',
  '/home/user/my-project'
);
client.sendTask('Analyze the codebase', (response) => {
  console.log('[RESPONSE]', response);
  client.sendTask('Fix the top 3 issues', (response2) => {
    console.log('[RESPONSE]', response2);
    client.close();
  });
});
```
### Node.js — Using Dockerode
```javascript
const Docker = require('dockerode');
const docker = new Docker();
async function runEvaTask(task, projectDir, llmUrl, llmModel) {
  const container = await docker.createContainer({
    Image: 'e-va-agent',
    Cmd: ['./e-va', '--pipe'],
    HostConfig: {
      Binds: [
        `${projectDir}:/workspace`,
      ],
      Memory: 4 * 1024 * 1024 * 1024, // 4GB
      NanoCpus: 2 * 1e9,               // 2 CPUs
    },
    Env: [
      `LLM_URL=${llmUrl}`,
      `LLM_MODEL=${llmModel}`,
    ],
    OpenStdin: true,
    StdinOnce: false,
    Tty: false,
  });
  await container.start();
  const stream = await container.attach({
    stdin: true,
    stdout: true,
    stderr: true,
    stream: true,
  });
  container.attachStream(stream, { stdin: true });
  stream.write(`${task}\nquit\n`);
  let output = '';
  stream.on('data', (data) => {
    output += data.toString();
  });
  return new Promise((resolve) => {
    stream.on('end', () => {
      container.remove();
      resolve(output);
    });
  });
}
// Usage
runEvaTask(
  'Implement a caching layer for the API',
  '/home/user/my-project',
  'http://localhost:8000/v1/chat/completions',
  'Qwen3.5-27B-AWQ'
).then(console.log);
```
---
## 8. Healthcheck & Lifecycle
### Built-in Healthcheck
The Dockerfile includes a healthcheck that verifies core binaries exist:
```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["bash", "-c", "test -x /opt/e-va/e-va && test -f /opt/e-va/agent.lua && test -x /usr/bin/google-chrome-stable && test -x /usr/bin/tini || exit 1"]
```
**Note**: This healthcheck verifies **binaries exist**, not that the agent is actively running. It allows the container to report healthy during idle periods.
### Checking Agent Runtime Status
To verify the agent process is actually running:
```bash
# Check if Lua agent is running
docker exec <container> pgrep -f 'lua.*agent\.lua'
# Check container health
docker inspect --format='{{.State.Health.Status}}' <container>
# View logs
docker logs -f <container>
```
### Process Management
The container uses `tini` as PID 1 for proper signal handling and zombie process reaping:
```dockerfile
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/e-va/e-va"]
CMD ["--pipe", "."]
```
### Signal Handling
| Signal | Effect |
|--------|--------|
| `SIGQUIT` | Stop signal (defined in Dockerfile `STOPSIGNAL`) |
| `SIGTERM` | Graceful shutdown via tini |
| `SIGINT` | Caught by `patcher_core.setup_sigint()` for cleanup |
### Graceful Shutdown
```bash
# Stop the container (sends STOPSIGNAL=SIGQUIT)
docker stop eva-container
# Or send SIGINT to the agent process
docker exec eva-container kill -INT 1
```
---
## 9. Security Model
### User Isolation
The agent runs as `chromeuser` (non-root) inside the container:
```dockerfile
RUN useradd -m -s /bin/bash chromeuser
USER chromeuser
```
### AGENT_HOME Protection
The `e-va` entry script warns if `AGENT_HOME` (`/opt/e-va`) is writable:
```bash
if [ -w "$AGENT_HOME" ]; then
    echo "[WARNING] AGENT_HOME ($AGENT_HOME) is writable by current user." >&2
fi
```
In Docker, `/opt/e-va` is owned by `root`, so `chromeuser` cannot modify agent files.
### Chrome Sandbox Restrictions
Chrome runs with mandatory flags for Docker compatibility:
```bash
# Chrome wrapper forces these flags regardless of how MCP invokes the browser
exec /usr/bin/google-chrome-stable-orig --no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage "$@"
```
### Sudo Restrictions
`chromeuser` has sudo access **only** for Chrome binaries:
```dockerfile
RUN echo "chromeuser ALL=(ALL) NOPASSWD: /usr/bin/google-chrome-stable, /usr/bin/google-chrome-stable-orig" > /etc/sudoers.d/chromeuser
```
### Recommendations
1. **Always mount volumes explicitly** — Don't use `:Z` or `:z` SELinux labels unless needed.
2. **Set resource limits** — Use `--memory` and `--cpus` to prevent runaway processes.
3. **Network isolation** — Use `--network` to restrict container network access.
4. **Read-only AGENT_HOME** — Never mount a writable volume over `/opt/e-va`.
---
## 10. Known Limitations
### State File Location
The agent saves state to `state.json` within the project directory. The path is determined by `agent/state.lua`:
```
/workspace/.e-va-conf/state.json
```
**Implication**: If you don't mount `.e-va-conf` as a volume, state is lost on container restart.
### Pipe Mode is Heavyweight
Each line sent via `--pipe` triggers the **full pipeline** (ARCHITECT planning → CODER implementation). This is not a lightweight chat interface. For rapid iteration, consider:
- Using `--agent CODER` to skip the planning stage
- Writing complex instructions to `task.txt` and running once
### No Native JSON API
The pipe protocol is line-based plain text. There is no built-in JSON RPC or REST API. For structured communication, wrap the pipe mode in a custom server (see Python/Node.js examples above).
### Single-Agent Container
Each container runs one agent session. For parallel tasks, run multiple containers:
```bash
docker run -d --name eva-1 -v /proj:/workspace e-va-agent ./e-va --pipe
docker run -d --name eva-2 -v /proj:/workspace e-va-agent ./e-va --pipe
```
### Chrome DevTools MCP
Browser automation requires Chrome to be accessible. In Docker:
- Chrome runs headless with `--no-sandbox`
- Shared memory usage is disabled (`--disable-dev-shm-usage`)
- If you need browser screenshots, ensure the `pictures/` directory is writable
### Context Window Limits
Default context limits from `config.lua`:
| Setting | Value |
|---------|-------|
| `MAX_CONTEXT` | 225,000 characters |
| `max_history_tokens` | 50,000 |
| `squash_threshold_tokens` | 180,000 |
| `max_recency_tokens` | 20,000 |
Long-running sessions may hit context limits. The agent auto-compresses history, but very long sessions may lose detail.
---
## 11. Troubleshooting
### Agent Won't Start
```bash
# Check if the entrypoint exists
docker run --rm e-va-agent ls -la /opt/e-va/e-va
# Check Lua version
docker run --rm e-va-agent lua -v
# Check if C extensions loaded
docker run --rm e-va-agent ls -la /opt/e-va/*.so
```
### LLM Connection Failed
```bash
# Test connectivity from inside the container
docker run --rm -it e-va-agent bash -c "curl -v $LLM_URL"
# Check if your LLM server is reachable from the Docker network
# Use --network host if the LLM is on localhost
docker run --network host -it --rm e-va-agent ./e-va --pipe
```
### State File Not Persisting
Ensure `.e-va-conf` is mounted:
```bash
# WRONG: State lost on container exit
docker run --rm -v /proj:/workspace e-va-agent ./e-va --pipe
# CORRECT: State persists
docker run --rm \
  -v /proj:/workspace \
  -v /proj/.e-va-conf:/workspace/.e-va-conf \
  e-va-agent ./e-va --pipe
```
### Chrome/Browser Errors
```bash
# Check Chrome is installed
docker run --rm e-va-agent google-chrome-stable --version
# Check Chrome wrapper
docker run --rm e-va-agent cat /usr/bin/google-chrome-stable
```
### Out of Memory
```bash
# Set explicit memory limit
docker run --memory 8g --cpus 4 e-va-agent ./e-va --pipe
# Monitor memory usage
docker stats eva-container
```
### Permission Denied on Workspace
```bash
# Ensure workspace is writable by chromeuser (UID 1000)
sudo chown -R 1000:1000 /path/to/project
# Or run with --user flag (not recommended, breaks Chrome sandbox)
docker run --user 1000:1000 e-va-agent ./e-va --pipe
```
### Debug Mode
Run the agent with verbose output:
```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  -e LLM_URL="http://your-llm:8000/v1/chat/completions" \
  -e LLM_MODEL="your-model" \
  e-va-agent bash -c "lua /opt/e-va/agent.lua --pipe"
```
Or use the API tester for LLM connectivity diagnostics:
```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  -e LLM_URL="http://your-llm:8000/v1/chat/completions" \
  -e LLM_MODEL="your-model" \
  e-va-agent bash -c "bash /opt/e-va/test_api.sh"
```
---
## Appendix A: Default Configuration Summary
Key defaults from `config.lua`:
```lua
-- LLM Defaults
AGENT_DEFAULTS = {
    url = os.getenv("LLM_URL") or "http://localhost:8000/v1/chat/completions",
    model = os.getenv("LLM_MODEL") or "default-model",
}
-- Pipeline Stages
PIPELINE = {
    { stage = "ANALYSIS_AND_PLANNING", agents = { "ARCHITECT" }, mode = "sequential" },
    { stage = "REVIEW_AND_CHAT", agents = { "ARCHITECT" }, mode = "interactive" },
    { stage = "IMPLEMENTATION", agents = { "CODER" }, mode = "sequential" }
}
-- Limits
LIMITS = {
    MAX_CONTEXT = 225000,
    MCP_MAX_OUTPUT_TOKENS = 16000,
}
-- Handoff
HANDOFF = {
    enabled = true,
    clear_history = "per_stage",
    auto_load_plan_files = true,
    feedback_to_architect = true,
}
```
## Appendix B: File Structure Reference
```
/opt/e-va/
├── e-va                    # Bash entry point
├── agent.lua               # Entry: requires agent/init.lua
├── agent/
│   ├── init.lua            # Main initialization
│   ├── cli.lua             # CLI argument parsing
│   ├── pipeline.lua        # Pipeline orchestration
│   ├── task.lua            # Task setup & pipe mode
│   ├── turn.lua            # Single agent turn execution
│   ├── config.lua          # Config loader
│   ├── state.lua           # State management
│   ├── custom_tools.lua    # Custom tool loader
│   ├── multi_stage.lua     # Multi-stage executor
│   └── bootstrap.lua       # Bootstrap mode
├── config.lua              # Default configuration
├── patcher_core.c          # C extension source
├── ipc_mcp.c               # C extension source
├── patcher_core.so         # Compiled patcher
├── ipc_mcp.so              # Compiled IPC
├── prompts/
│   ├── architect.md        # ARCHITECT system prompt
│   └── coder.md            # CODER system prompt
├── utils.lua               # Utility functions
├── logger.lua              # Logging module
├── context_flow.lua        # Context management
├── tools.lua               # Tool definitions
├── tool_registry.lua       # Tool registry
├── llm_handler.lua         # LLM request handler
├── Makefile                # Build C extensions
├── Dockerfile              # Container definition
├── api_tester.lua          # LLM connectivity tester
└── test_api.sh             # API tester wrapper
```
