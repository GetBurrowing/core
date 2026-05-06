---
name: agent-chrome-cdp
description: Set up a dedicated Chrome (or Chromium) instance with Chrome DevTools Protocol enabled on `127.0.0.1:9222`, so an agent can drive web UIs (Suite dev server, GitHub, dashboards) for navigation, screenshots, and DOM inspection. Covers cross-platform binary discovery, headless vs headed tradeoffs, a curl health check, a minimal Python CDP example, and how to keep the browser running across agent sessions via systemd / launchd / Task Scheduler.
---

# Agent Chrome (CDP)

This skill stands up a **dedicated, agent-owned Chrome** with the Chrome DevTools
Protocol bound to `127.0.0.1:9222`. The agent attaches to that port and drives
the browser for navigation, screenshots, and DOM inspection.

This is intentionally separate from your day-to-day Chrome profile:

- A dedicated `--user-data-dir` keeps cookies, extensions, and history out of
  your agent's blast radius.
- Bound to `127.0.0.1` only, so nothing on the network can attach.
- No first-run setup, no default-browser nag, and background networking is off
  to keep the process predictable.

## 1. Find the Chrome binary

| OS | Likely paths |
|---|---|
| **macOS** | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` (Chrome) or `/Applications/Chromium.app/Contents/MacOS/Chromium` |
| **Linux** | `google-chrome` / `google-chrome-stable` / `chromium` / `chromium-browser` (whichever the package manager installed) |
| **Windows** | `C:\Program Files\Google\Chrome\Application\chrome.exe` or `C:\Program Files (x86)\Google\Chrome\Application\chrome.exe` |

The helper `scripts/launch-chrome.sh` auto-discovers the binary on macOS and
Linux. On Windows, run from PowerShell using `scripts/launch-chrome.ps1`.

## 2. Launch with CDP enabled

The flags below are the canonical "agent profile" launch:

```
--remote-debugging-port=9222
--remote-debugging-address=127.0.0.1
--user-data-dir=<dedicated profile dir>
--no-first-run
--no-default-browser-check
--disable-background-networking
--disable-default-apps
```

### macOS / Linux

```bash
skills/agent-chrome-cdp/scripts/launch-chrome.sh
# Defaults: profile dir = $HOME/.cache/agent-chrome-profile, headed
```

To launch headless (no visible window — appropriate for unattended runs):

```bash
HEADLESS=1 skills/agent-chrome-cdp/scripts/launch-chrome.sh
```

### Windows

```powershell
.\skills\agent-chrome-cdp\scripts\launch-chrome.ps1
# Add -Headless to run without a window.
```

## 3. Headless vs headed

| Mode | When to use |
|---|---|
| **Headed** | Visual review work, debugging by watching the screen, anything where you'll also screen-share or look at the browser yourself. |
| **Headless** | Unattended runs, CI, hosts without a display server, anywhere you only consume the rendered output via CDP. Modern Chrome's `--headless=new` is feature-equivalent to headed for screenshots and DOM. |

Headed Chrome on Linux requires an X11 / Wayland display (`$DISPLAY` set) or a
virtual display like `Xvfb`. On a headless server, prefer `--headless=new` —
the helper script does this automatically when `HEADLESS=1`.

## 4. Verify the connection

Once the browser is running, check the protocol endpoint:

```bash
curl -s http://127.0.0.1:9222/json/version | jq .
```

Expected output:

```json
{
  "Browser": "Chrome/<version>",
  "Protocol-Version": "1.3",
  "User-Agent": "Mozilla/5.0 (...) Chrome/...",
  "V8-Version": "...",
  "WebKit-Version": "...",
  "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/browser/<uuid>"
}
```

If `curl` reports "Connection refused", Chrome isn't listening — check that the
helper script's PID is still alive (`cat $HOME/.cache/agent-chrome-profile/chrome.pid`).

## 5. Drive the browser from Python

The included `scripts/cdp_navigate.py` connects to `ws://127.0.0.1:9222`,
opens a target, navigates to a URL, waits for the load event, and prints the
final URL. Dependencies: standard library only (uses `websockets` if available,
falls back to a tiny urllib + sockets implementation).

```bash
python3 skills/agent-chrome-cdp/scripts/cdp_navigate.py http://localhost:4001/dev/login
```

For richer driving, install [Playwright](https://playwright.dev/python/docs/api/class-browsertype#browser-type-connect-over-cdp)
and use `connect_over_cdp("http://127.0.0.1:9222")`:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.connect_over_cdp("http://127.0.0.1:9222")
    ctx = browser.contexts[0] if browser.contexts else browser.new_context()
    page = ctx.new_page()
    page.goto("http://localhost:4001/dev/login")
    page.screenshot(path="/tmp/dev-login.png", full_page=True)
```

## 6. Keep it running across agent sessions

You usually want the dedicated Chrome to outlive any individual agent invocation
so attaching is instant.

### macOS (launchd)

`scripts/com.startup-suite.agent-chrome.plist.example` is a launchd template.
Copy it to `~/Library/LaunchAgents/`, edit the `ProgramArguments` to point at
your Chrome binary and your profile dir, then:

```bash
launchctl load -w ~/Library/LaunchAgents/com.startup-suite.agent-chrome.plist
launchctl list | grep agent-chrome
```

### Linux (systemd user)

`scripts/agent-chrome.service.example` is a systemd user-unit template. Drop it
at `~/.config/systemd/user/agent-chrome.service`, edit the `ExecStart`, then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now agent-chrome.service
systemctl --user status agent-chrome.service
```

### Windows (Task Scheduler)

Create a "At log on" task that runs the launch PowerShell script:

```powershell
schtasks /Create /TN "AgentChromeCDP" /SC ONLOGON `
  /TR "powershell -NoProfile -WindowStyle Hidden -File C:\path\to\launch-chrome.ps1"
```

## 7. Stop it

```bash
skills/agent-chrome-cdp/scripts/stop-chrome.sh
```

The stop script reads `<profile dir>/chrome.pid` and sends SIGTERM. It refuses
to kill the listener on `:9222` if no PID file is present (could be your
day-to-day Chrome with debugging accidentally enabled).

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `bind() to :9222 failed (98: Address already in use)` | Another Chrome (perhaps your day-to-day one) holds 9222. | Pick a different port (`PORT=9223 launch-chrome.sh`) and update consumers. |
| `Cannot connect to display` (Linux, headed) | No X server / Wayland session. | Use `HEADLESS=1` or run under Xvfb. |
| Screenshots all white | Page hasn't finished rendering. | Wait for `Page.loadEventFired` (the helper does), or sleep for fonts. |
| Profile lock files left behind after a crash | SingletonLock / SingletonSocket in user data dir. | `rm $HOME/.cache/agent-chrome-profile/Singleton*` and relaunch. |
