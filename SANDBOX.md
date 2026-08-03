# E-va Agent Sandbox
The **Sandbox** provides an isolated, reproducible environment for running E-va Agent tasks. Each task executes inside a Docker container with controlled resources, ensuring safety and consistency.
## Prerequisites
1. **Docker** installed and running (Docker Desktop, Podman, or native Docker Engine)
2. A `.env` file in the project root containing your LLM API keys:
```env
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```
## Quick Start
```bash
# 1. Build the agent image (first time only)
docker build -t e-va-agent .
# 2. Run a task
./sandbox_run.sh "Analyze the codebase and suggest improvements"
# 3. View results
cat sandbox-workspace/.e-va-conf/result.log
```
## Usage Modes
### Mode 1: One-Liner Task
Pass a task instruction directly as an argument:
```bash
./sandbox_run.sh "Refactor the utils module to use local functions"
```
Optionally specify a maximum number of turns:
```bash
./sandbox_run.sh "Implement a new logging feature" 10
```
### Mode 2: File-Based Task
Pipe the contents of a task file into the runner:
```bash
cat .e-va-conf/task.txt | ./sandbox_run.sh
```
Or use process substitution:
```bash
./sandbox_run.sh < my_complex_task.txt
```
### Mode 3: Interactive Pipe Mode
Run without arguments for an interactive session:
```bash
docker run -it --rm \
    -v "$(pwd)/sandbox-workspace:/workspace" \
    -v "$(pwd)/.env:/opt/e-va/.env:ro" \
    --memory=4g --cpus=2 \
    -p 8080:8080 \
    e-va-agent --pipe .
```
### Mode 4: Clean Workspace Run
Wipe the workspace before running a task to ensure a fresh state:
```bash
./sandbox_run.sh --clean "Implement a new feature from scratch"
```
### Mode 5: Snapshot Before Run
Create a snapshot of the current workspace state before running a task:
```bash
./sandbox_run.sh --snapshot pre-refactor "Refactor the utils module"
```
Snapshots are stored in `sandbox-workspace/.snapshots/` as `.tar.gz` files. You can restore a snapshot by extracting it:
```bash
tar -xzf sandbox-workspace/.snapshots/pre-refactor.tar.gz -C sandbox-workspace/
```
## Workspace Snapshots
The `--snapshot NAME` flag creates a compressed archive of the entire workspace before the agent runs. This is useful for:
- **Reproducible runs**: Capture the exact state before a transformation
- **Rollback**: Restore a previous workspace state if needed
- **Comparison**: Diff snapshots to see what the agent changed
Snapshots are stored in `sandbox-workspace/.snapshots/<NAME>.tar.gz`.
## Result Extraction
The sandbox runner extracts results using a tiered fallback strategy:
1. **Primary**: Content between `=== RESPONSE START ===` and `=== RESPONSE END ===` markers
2. **Fallback 1**: Last JSON object from the output (if markers are missing)
3. **Fallback 2**: Last 50 lines of the log (if no JSON found)
Full raw output is always saved to `sandbox-workspace/.e-va-conf/result.log`.
## Port Mapping
The sandbox uses explicit port mapping (`-p ${STATUS_PORT}:${STATUS_PORT}`) instead of `--network host`. This ensures:
- **Portability**: Works correctly on both Linux and macOS/Windows Docker setups
- **Security**: Only the status port is exposed, not the entire host network
- **Predictability**: The status server is always accessible at `http://localhost:${STATUS_PORT}`
## Volume Mount Structure
| Host Path | Container Path | Purpose |
|-----------|----------------|---------|
| `./sandbox-workspace/` | `/workspace/` | Project workspace (read/write) |
| `./.env` | `/opt/e-va/.env` | API keys (read-only) |
| `./` (source) | `/opt/e-va/` | Agent code (baked into image) |
### Where to Find Results
- **Raw output**: `sandbox-workspace/.e-va-conf/result.log`
- **Modified files**: Inside `sandbox-workspace/` (mirrors the container's `/workspace`)
- **Agent logs**: `sandbox-workspace/.e-va-conf/logs/`
## Docker Compose Alternative
For more complex setups, use the provided `docker-compose.sandbox.yml`:
```bash
# Run interactively
docker compose -f docker-compose.sandbox.yml run --rm eva-sandbox
# Run a one-off task
echo "Review the Dockerfile for security issues" | \
    docker compose -f docker-compose.sandbox.yml run --rm eva-sandbox
```
## Resource Limits
The sandbox enforces resource constraints by default:
| Resource | Limit | Override |
|----------|-------|----------|
| Memory | 4 GB | `--memory=8g` |
| CPUs | 2 cores | `--cpus=4` |
To override limits in `sandbox_run.sh`, edit the `docker run` command directly or use Docker Compose profiles.
## Troubleshooting
### Missing API Keys
**Symptom**: Agent fails with authentication errors.
**Fix**: Ensure `.env` exists and contains valid keys:
```bash
ls -la .env
grep OPENAI_API_KEY .env
```
### Permission Denied on Volume Mounts
**Symptom**: `Permission denied` when accessing `/workspace`.
**Fix**: Ensure the workspace directory has correct permissions:
```bash
chmod 755 sandbox-workspace
chown -R $(id -u):$(id -g) sandbox-workspace
```
### Chrome Sandbox Issues
**Symptom**: Browser automation fails with sandbox errors.
**Fix**: The Dockerfile already wraps Chrome with `--no-sandbox` flags. If issues persist, verify the wrapper:
```bash
docker run --rm e-va-agent cat /usr/bin/google-chrome-stable
```
### Image Not Found
**Symptom**: `docker: image 'e-va-agent' not found`.
**Fix**: Build the image first:
```bash
docker build -t e-va-agent .
```
### Out of Memory
**Symptom**: Container killed with OOM error.
**Fix**: Increase memory limit:
```bash
# In sandbox_run.sh, change --memory=4g to --memory=8g
# Or in docker-compose.sandbox.yml, update deploy.resources.limits.memory
```
### Stale Workspace State
**Symptom**: Unexpected files or state from previous runs.
**Fix**: Use the `--clean` flag to wipe the workspace before running:
```bash
./sandbox_run.sh --clean "Your task instruction"
```
Or manually clear the workspace:
```bash
rm -rf sandbox-workspace
mkdir -p sandbox-workspace/.e-va-conf
```