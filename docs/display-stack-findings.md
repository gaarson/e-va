# Display Stack & Browser Automation — Findings
> **Status:** Verified working (Intel iGPU + Wayland + VNC + Chrome CDP + MCP)
> **Date:** 2026-08-15
> **Tested on:** Laptop with Intel Iris Xe (Raptor Lake-P) + NVIDIA RTX 4050 (hybrid)
---
## 1. Architecture Overview
```
┌─────────────────────────────────────────────────────────────────────┐
│ CONTAINER (e-va-agent)                                              │
│                                                                     │
│  init.sh (root)                                                     │
│       │                                                             │
│       ├── WLR_DRM_DEVICES=/dev/dri/renderD128 (Intel only!)         │
│       ├── XDG_RUNTIME_DIR=/tmp/xdg                                  │
│       │                                                             │
│       ├── cage -x &          ← Wayland compositor (wlroots)         │
│       │       └── /tmp/xdg/wayland-0 (socket)                       │
│       │                                                             │
│       ├── google-chrome-stable &                                    │
│       │       --ozone-platform=wayland                              │
│       │       --disable-gpu                                         │
│       │       --remote-debugging-port=9222                          │
│       │       └── CDP endpoint: http://127.0.0.1:9222               │
│       │                                                             │
│       ├── wayvnc -a 0.0.0.0:5900 &                                 │
│       │       └── VNC server on port 5900                           │
│       │                                                             │
│       └── su chromeuser → e-va agent                                │
│               └── MCP: chrome-devtools-mcp --browserUrl :9222        │
│                       └── Agent controls Chrome via CDP              │
└─────────────────────────────────────────────────────────────────────┘
```
---
## 2. Requirements & Constraints
| Requirement | Value | Reason |
|-------------|-------|--------|
| GPU | **Intel iGPU ONLY** (`renderD128`) | NVIDIA causes "Device or resource busy" if host has active session. NVIDIA drivers conflict with container DRM master acquisition. |
| User for display stack | **root** | DRM master requires root or video group membership. `chromeuser` cannot acquire DRM. |
| Chrome flag | `--disable-gpu` | Software rendering avoids GPU driver issues inside container. |
| Cage flag | `-x` (no XWayland) | XWayland binary not installed; not needed for Wayland-native apps. |
| Env var | `WLR_DRM_DEVICES=/dev/dri/renderD128` | Restricts wlroots to Intel render node, avoids NVIDIA probe failures. |
| XDG_RUNTIME_DIR | `/tmp/xdg` (chmod 700) | Required by cage/wlroots for socket placement. |
### ⚠️ CRITICAL WARNING
**Do NOT pass `--gpus all` or mount `/dev/dri/card1` (NVIDIA) when the host has an active graphical session on NVIDIA.** This will KILL the host desktop session. Always use Intel-only mode on hybrid laptops.
---
## 3. Working Configuration (Verified)
### 3.1 Docker Run Command
```bash
docker run -d --name eva-vnc-test \
    --device /dev/dri/renderD128 \
    --device /dev/dri/card0 \
    --memory=4g --cpus=2 \
    --network host \
    -v "$(pwd)/docker/sandbox-workspace:/workspace" \
    -v "$(pwd)/.env:/opt/e-va/.env:ro" \
    e-va-agent \
    bash -c '
        mkdir -p /tmp/xdg && chmod 700 /tmp/xdg;
        export XDG_RUNTIME_DIR=/tmp/xdg;
        export WLR_DRM_DEVICES="/dev/dri/renderD128";
        cage -x &
        sleep 3;
        export WAYLAND_DISPLAY=wayland-0;
        google-chrome-stable --no-sandbox --ozone-platform=wayland \
            --disable-gpu --remote-debugging-port=9222 \
            --new-window about:blank &
        sleep 5;
        wayvnc -a 0.0.0.0:5900 &
        wait
    '
```
### 3.2 Ports Exposed
| Port | Service | Purpose |
|------|---------|---------|
| 5900 | WayVNC | VNC client connection (Remmina, RealVNC, etc.) |
| 9222 | Chrome DevTools Protocol | MCP browser automation |
| 8080 | E-VA Status Server | Agent monitoring |
### 3.3 VNC Client Connection
Connect any VNC client to `host_ip:5900` (no password). Verified working with **Remmina**.
**Note:** If no physical monitor is connected to the Intel eDP output, cage reports `"Atomic commit failed: Permission denied"` on eDP-1 but still creates a virtual output. WayVNC may show `"No display buffer has been set"` warnings initially but will work once Chrome renders content.
---
## 4. MCP Browser Integration
### 4.1 Config File
**Location:** `.e-va-conf/config.lua` (in workspace, mounted at `/workspace/.e-va-conf/config.lua`)
```lua
local M = {}
function M.get()
    return {
        MCP_SERVERS = {
            browser = "chrome-devtools-mcp --browserUrl http://127.0.0.1:9222 --screenshot-format=jpeg --screenshot-quality=70 --screenshot-max-width=1024 --screenshot-max-height=768 --no-usage-statistics --no-performance-crux"
        },
        AGENTS = {
            EXECUTOR = {
                name = "EXECUTOR",
                prompt_file = "prompts/executor.md",
                allowed_tools = {
                    "shell", "read_file", "read_chunk", "create_file", "patch",
                    "search", "explore_tree", "task_complete", "outline",
                    "pin", "unpin", "optimize_context",
                    "mcp_browser_*",
                },
                params = {
                    stream = true,
                    temperature = 0.1,
                    top_p = 0.95,
                    max_tokens = 16384,
                    repetition_penalty = 1.05,
                },
                model = "local_model",
            }
        },
        PIPELINE = {
            { stage = "EXECUTE", agents = { "EXECUTOR" }, mode = "sequential" }
        },
        PIPELINE_SETTINGS = {
            MAX_TURNS = 50,
            ABORT_ON_FATAL = true,
        }
    }
end
return M
```
### 4.2 How It Works
1. `init.sh` starts Chrome with `--remote-debugging-port=9222`
2. Agent starts → loads config → sees `MCP_SERVERS.browser`
3. Agent spawns `chrome-devtools-mcp` process via `ipc_mcp.so` (fork+pipe)
4. MCP server connects to existing Chrome via `--browserUrl http://127.0.0.1:9222`
5. Agent gets `mcp_browser_*` tools
### 4.3 Available MCP Tools (prefix `mcp_browser_`)
| Tool | Purpose |
|------|---------|
| `navigate_page` | Navigate to URL |
| `take_screenshot` | Capture page as JPEG/PNG |
| `click` / `fill` / `select_option` | Form interaction |
| `evaluate_script` | Run JavaScript in page context |
| `list_pages` / `select_page` | Multi-tab management |
| `wait_for` | Wait for selector/text |
| `get_network_request` | Inspect network traffic |
---
## 5. init.sh Display Stack Logic
The `docker/init.sh` script includes conditional display stack startup:
```bash
# Only if DRM devices are available
if [ -d /dev/dri ] && [ "$(ls /dev/dri/renderD* 2>/dev/null | wc -l)" -gt 0 ]; then
    echo "[DISPLAY] Starting display stack (cage + chrome + wayvnc)..." >&2
    
    # Setup XDG runtime dir
    mkdir -p /tmp/xdg && chmod 700 /tmp/xdg
    export XDG_RUNTIME_DIR=/tmp/xdg
    
    # Start cage (Wayland compositor) - use Intel card only to avoid NVIDIA conflicts
    export WLR_DRM_DEVICES="/dev/dri/renderD128"
    cage -x &
    CAGE_PID=$!
    
    # Wait for Wayland socket
    sleep 3
    export WAYLAND_DISPLAY=wayland-0
    
    # Start Chrome with remote debugging
    google-chrome-stable \
        --no-sandbox \
        --ozone-platform=wayland \
        --disable-gpu \
        --remote-debugging-port=9222 \
        --new-window about:blank &
    CHROME_PID=$!
    
    # Wait for Chrome DevTools port
    sleep 5
    
    # Start wayvnc
    wayvnc -a 0.0.0.0:5900 &
    WAYVNC_PID=$!
    
    echo "[DISPLAY] Display stack ready: VNC on :5900, Chrome DevTools on :9222" >&2
else
    echo "[DISPLAY] No DRM render devices found, skipping display stack" >&2
fi
```
If no DRM devices are present (e.g., CI environment without GPU), the display stack is skipped gracefully and the agent runs headless.
---
## 6. Troubleshooting
| Symptom | Cause | Fix |
|---------|-------|-----|
| Host NVIDIA session crashes | Container grabbed NVIDIA DRM master | Use `WLR_DRM_DEVICES=/dev/dri/renderD128` (Intel only). Never pass `--gpus all` on hybrid laptops. |
| `Could not make device fd drm master: Device or resource busy` | Another process holds DRM (host session) | Use Intel card instead of NVIDIA. Or stop host session. |
| `Failed to initialize EGL` + `ERROR_INCOMPATIBLE_DRIVER` | NVIDIA driver not accessible in container | Expected when using Intel-only mode. Cage falls back to Mesa software rendering. |
| `No display buffer has been set` (WayVNC) | No physical output enabled on Intel eDP | Normal in headless/laptop-lid-closed scenario. VNC still works once Chrome renders. |
| `Cannot find Xwayland binary` | XWayland not installed | Use `cage -x` to disable XWayland. Not needed for Wayland-native apps. |
| `libinput initialization failed, no input devices` | No USB input devices in container | Set `WLR_LIBINPUT_NO_DEVICES=1` or ignore (VNC provides input). |
| Chrome: `Missing X server or $DISPLAY` | Chrome started before Wayland socket ready | Increase sleep between cage start and chrome launch (3s minimum). |
| VNC black screen | Chrome not yet rendered first frame | Wait 5-10 seconds after Chrome launch. Verify Chrome is running (`ps aux`). |
| `pci id for fd N: 10de:XXXX, driver (null)` | NVIDIA PCI device probed but no driver | Harmless warning. Ignore when using Intel-only mode. |
---
## 7. Headless Mode (No GPU at All)
For environments without any GPU (CI servers, cloud VMs):
```bash
docker run -i --rm \
    -v "$(pwd)/docker/sandbox-workspace:/workspace" \
    -v "$(pwd)/.env:/opt/e-va/.env:ro" \
    --memory=4g --cpus=2 \
    e-va-agent --pipe .
```
In this case:
- `init.sh` detects no `/dev/dri/renderD*` → skips display stack
- Agent runs without browser capabilities
- MCP browser tools unavailable (no Chrome running)
- All other tools (shell, file ops, search) work normally
### 7.1 Headless Chrome Alternative
To get browser automation in headless mode without a display server:
```bash
# Inside container, alternative to cage+chrome:
google-chrome-stable --headless --no-sandbox --remote-debugging-port=9222 about:blank &
```
This gives CDP access without needing a display server. Screenshots will be of the virtual viewport only (default 800x600, configurable via `--window-size=WxH`).
### 7.2 Recommended for Production (No Physical Display)
```bash
# Best option: headless Chrome + no cage/wayvnc
# Saves ~200MB RAM vs full display stack
google-chrome-stable --headless=new --no-sandbox \
    --remote-debugging-port=9222 \
    --window-size=1920,1080 \
    --disable-gpu \
    about:blank &
```
Agent can still use all `mcp_browser_*` tools. No VNC needed since there's no visual output to observe.
---
## 8. Performance Notes
| Component | CPU Usage | RAM Usage | Notes |
|-----------|-----------|-----------|-------|
| cage (wlroots) | ~45% idle (Intel) | ~12 MB | High CPU due to polling loop with no real output |
| Chrome (about:blank) | ~50% idle | ~150 MB | `--disable-gpu` forces software compositing |
| wayvnc | <1% | ~40 MB | Idle until VNC client connects |
| **Total display stack** | **~95%** | **~200 MB** | Significant overhead for simple tasks |
**Recommendation:** For tasks that don't need visual verification, prefer headless Chrome mode. Use full display stack only when you need to visually observe agent behavior via VNC.
---
## 9. Key Learnings
1. **Intel iGPU is the safe choice** for containers on hybrid laptops. NVIDIA DRM master conflicts are fatal to host sessions.
2. **`WLR_DRM_DEVICES`** is the critical env var that prevents wlroots from probing NVIDIA.
3. **`--disable-gpu` on Chrome** is essential — without it, Chrome tries to use the GPU directly and fails.
4. **`cage -x`** avoids the XWayland dependency entirely.
5. **Sleep timing matters**: 3s for cage→chrome, 5s for chrome→wayvnc. Too short = race conditions.
6. **VNC works even without physical display** — the "Permission denied" on eDP atomic commits is cosmetic.
7. **MCP integration is transparent** — agent just needs `MCP_SERVERS` in config and `mcp_browser_*` in allowed_tools.
8. **Headless Chrome is production-ready** for automated browser tasks without human observation.
