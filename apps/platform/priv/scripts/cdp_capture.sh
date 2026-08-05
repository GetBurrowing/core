#!/usr/bin/env bash
#
# cdp_capture.sh — single-shot screenshot helper for the dispatch evidence flow.
#
# Drives a local headless Chrome via the Chrome DevTools Protocol (CDP),
# navigates to a URL, optionally applies an
# Emulation.setDeviceMetricsOverride for mobile viewports, and writes a JPEG
# (Page.captureScreenshot, quality 80) to the requested path.
#
# Usage:
#   cdp_capture.sh <url> <output.jpg> [--width N --height N] [--cdp HOST:PORT]
#
# Examples:
#   cdp_capture.sh https://example.com /tmp/example.jpg
#   cdp_capture.sh https://example.com /tmp/example.jpg --width 375 --height 812
#   cdp_capture.sh http://localhost:4000 /tmp/dev.jpg --cdp 127.0.0.1:9222
#
# Prerequisites (per host, NOT enforced by this script):
#   - A headless Chrome must be running with --remote-debugging-port=<PORT>
#     (default 9222). On hive this is the dedicated CDP profile under
#     ~/.openclaw/chrome-cdp-profile. The endpoint is auto-detected across
#     both loopback families — 127.0.0.1 first, then [::1] — because Chrome
#     >=150 on macOS binds the DevTools listener to [::1] even when given
#     --remote-debugging-address=127.0.0.1. Pass --cdp to pin one explicitly.
#     If no candidate answers, the script exits non-zero with a clear message.
#   - Python 3.10+ with the `websockets` package (Ubuntu's python3-websockets
#     is fine; Suite's container image already has it).
#
# Exit codes:
#   0  success — JPEG written
#   2  bad arguments / --help requested
#   3  CDP unreachable on the configured host:port
#   4  CDP target/navigation failure (timeouts surfaced via stderr)

set -euo pipefail

usage() {
  cat <<'EOF'
cdp_capture.sh — single-shot CDP screenshot helper

USAGE
  cdp_capture.sh <url> <output.jpg> [--width N --height N] [--cdp HOST:PORT]

OPTIONS
  --width N         Viewport width (used together with --height)
  --height N        Viewport height (used together with --width)
  --cdp HOST:PORT   Pin the CDP endpoint. Omit to auto-detect, which probes
                    127.0.0.1:PORT then [::1]:PORT (PORT from \$CDP_PORT,
                    default 9222).
  -h, --help        Show this message

PREREQUISITES
  Headless Chrome must be running with --remote-debugging-port=<PORT>. Both
  loopback families are probed, so a Chrome that binds only [::1] (macOS,
  Chrome >=150) is found without extra flags. If none answer, this exits 3.
EOF
}

if [[ $# -lt 2 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
  if [[ $# -lt 2 ]]; then exit 2; else exit 0; fi
fi

URL="$1"
OUTPUT="$2"
shift 2

WIDTH=""
HEIGHT=""
CDP_HOSTPORT=""
CDP_PORT="${CDP_PORT:-9222}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --width)
      WIDTH="$2"; shift 2 ;;
    --height)
      HEIGHT="$2"; shift 2 ;;
    --cdp)
      CDP_HOSTPORT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "cdp_capture.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

probe_cdp() {
  curl -sf "http://${1}/json/version" >/dev/null 2>&1
}

# Sanity check the CDP endpoint up front so the Python helper can assume it
# works. This is also the documented "is Chrome up?" probe.
#
# When the caller pins --cdp we probe exactly that and nothing else. Otherwise
# we try both loopback families: Chrome >=150 on macOS binds the DevTools
# listener to [::1] even when launched with --remote-debugging-address=127.0.0.1,
# so an IPv4-only probe reports a perfectly healthy browser as unreachable.
if [[ -n "$CDP_HOSTPORT" ]]; then
  CDP_CANDIDATES=("$CDP_HOSTPORT")
else
  CDP_CANDIDATES=("127.0.0.1:${CDP_PORT}" "[::1]:${CDP_PORT}")
fi

CDP_FOUND=""
for candidate in "${CDP_CANDIDATES[@]}"; do
  if probe_cdp "$candidate"; then
    CDP_FOUND="$candidate"
    break
  fi
done

if [[ -z "$CDP_FOUND" ]]; then
  cat <<EOF >&2
cdp_capture.sh: no CDP endpoint reachable (tried: ${CDP_CANDIDATES[*]}).
                Start a headless Chrome with --remote-debugging-port (on hive,
                this is the chrome-cdp-profile process; see ~/.openclaw skills)
                and retry. Exit code 3.
EOF
  exit 3
fi

CDP_HOSTPORT="$CDP_FOUND"

PYTHON_BIN="${PYTHON_BIN:-python3}"

CDP_HOSTPORT="$CDP_HOSTPORT" \
URL="$URL" \
OUTPUT="$OUTPUT" \
WIDTH="$WIDTH" \
HEIGHT="$HEIGHT" \
exec "$PYTHON_BIN" - <<'PYEOF'
import asyncio
import base64
import json
import os
import sys
import urllib.request

import websockets


CDP_HOSTPORT = os.environ["CDP_HOSTPORT"]
URL = os.environ["URL"]
OUTPUT = os.environ["OUTPUT"]
WIDTH = os.environ.get("WIDTH") or ""
HEIGHT = os.environ.get("HEIGHT") or ""

NAV_TIMEOUT_S = 15.0
LOAD_FALLBACK_S = 3.0


def fail(code: int, msg: str) -> None:
    print(f"cdp_capture.sh: {msg}", file=sys.stderr)
    sys.exit(code)


def http_json(path: str):
    req = urllib.request.Request(f"http://{CDP_HOSTPORT}{path}",
                                 method="GET")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode("utf-8"))


def http_put(path: str):
    req = urllib.request.Request(f"http://{CDP_HOSTPORT}{path}",
                                 method="PUT")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode("utf-8"))


async def cdp_call(ws, msg_id: int, method: str, params: dict | None = None):
    payload = {"id": msg_id, "method": method}
    if params is not None:
        payload["params"] = params
    await ws.send(json.dumps(payload))
    while True:
        raw = await ws.recv()
        msg = json.loads(raw)
        if msg.get("id") == msg_id:
            if "error" in msg:
                raise RuntimeError(
                    f"CDP error in {method}: {msg['error']}"
                )
            return msg.get("result", {})
        # Otherwise it's an unrelated event — drop it.


async def wait_for_event(ws, method: str, timeout_s: float):
    """Drain incoming frames until we see the requested CDP event."""
    try:
        async with asyncio.timeout(timeout_s):
            while True:
                raw = await ws.recv()
                msg = json.loads(raw)
                if msg.get("method") == method:
                    return msg.get("params", {})
    except asyncio.TimeoutError:
        return None


async def run() -> int:
    # Pick or create a target. Prefer creating a fresh one so concurrent
    # captures don't clobber each other.
    try:
        target = http_put(f"/json/new?{URL}")
    except Exception as e:
        fail(4, f"failed to create CDP target via /json/new: {e}")
        return 4  # unreachable

    target_id = target.get("id")
    ws_url = target.get("webSocketDebuggerUrl")
    if not ws_url:
        fail(4, f"CDP /json/new returned no webSocketDebuggerUrl: {target}")
        return 4

    rc = 0
    try:
        async with websockets.connect(ws_url, max_size=64 * 1024 * 1024) as ws:
            await cdp_call(ws, 1, "Page.enable")

            if WIDTH and HEIGHT:
                await cdp_call(
                    ws,
                    2,
                    "Emulation.setDeviceMetricsOverride",
                    {
                        "width": int(WIDTH),
                        "height": int(HEIGHT),
                        "deviceScaleFactor": 2,
                        "mobile": True,
                    },
                )

            # /json/new already navigated, but issue an explicit Page.navigate
            # so we can correlate the load event reliably.
            await cdp_call(ws, 3, "Page.navigate", {"url": URL})

            # Wait for the page load event with a soft fallback so a slow
            # network doesn't lose us a screenshot entirely.
            loaded = await wait_for_event(
                ws, "Page.loadEventFired", NAV_TIMEOUT_S
            )
            if loaded is None:
                # Give the renderer a beat to settle even without an explicit
                # load event (SPAs that never fire one).
                await asyncio.sleep(LOAD_FALLBACK_S)

            shot = await cdp_call(
                ws,
                4,
                "Page.captureScreenshot",
                {"format": "jpeg", "quality": 80},
            )

            data_b64 = shot.get("data")
            if not data_b64:
                fail(4, "Page.captureScreenshot returned empty data")
                return 4

            with open(OUTPUT, "wb") as fh:
                fh.write(base64.b64decode(data_b64))
    except Exception as e:
        print(f"cdp_capture.sh: CDP session failed: {e}", file=sys.stderr)
        rc = 4
    finally:
        # Best-effort target cleanup. Failure to close is non-fatal.
        try:
            http_json(f"/json/close/{target_id}")
        except Exception:
            pass

    return rc


sys.exit(asyncio.run(run()))
PYEOF
