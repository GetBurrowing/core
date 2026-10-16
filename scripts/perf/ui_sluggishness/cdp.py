"""Minimal CDP driver for the ui_sluggishness harness (task 01a13884 stage 1).

Shared by audit.py, profile.py and chatclick.py. Dependencies: Python 3 and
`websocket-client` (`pip install websocket-client`).

Every run gets its OWN browser context (created here, disposed on close), so a
shared Chrome's default context and cookies are never touched. Sign-in is the
dev rig's `/dev/login`; the harness refuses production hosts outright.

LiveView frame attribution
--------------------------
`attribute(frames)` parses each received LiveView frame
(`[join_ref, ref, topic, event, payload]`), finds the rendered diff (the
`diff` push, or `response.diff` / `response.rendered` in a `phx_reply`) and
sums the serialized JSON size per top-level component cid (`c.<cid>`) and per
root key. `cid_names()` maps cids to components via `[data-phx-component]`
in the live DOM.
"""

import argparse
import json
import os
import re
import time
import urllib.parse
import urllib.request

import websocket

TASK_ID = "01a13884-c3dd-7001-8c37-348649ef785e"

# Hosts this harness must never drive. It measures the dev rig only.
FORBIDDEN_HOST_PATTERNS = (r"(^|\.)example\.com$", r"(^|\.)ellis\.technology$")

LONGTASK_OBSERVER = (
    "window.__lt=window.__lt||[];"
    "try{new PerformanceObserver(l=>l.getEntries().forEach("
    "e=>window.__lt.push(Math.round(e.duration)))).observe({type:'longtask',buffered:true})}"
    "catch(e){}"
)


def common_args(description):
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--cdp", default="127.0.0.1:9222", help="Chrome DevTools host:port")
    p.add_argument(
        "--base-url",
        required=True,
        help="dev server origin, e.g. http://192.0.2.200:4020 (never a prod host)",
    )
    p.add_argument(
        "--out-dir",
        default=None,
        help="output dir (default ~/sources/tmp/ui-sluggishness-<task-id>-<pid>/)",
    )
    p.add_argument("--width", type=int, default=1440)
    p.add_argument("--height", type=int, default=900)
    p.add_argument(
        "--login-as",
        default=None,
        help="optional /dev/login?as=<slug>; default is the stock Dev User",
    )
    return p


def check_base_url(base_url):
    host = urllib.parse.urlparse(base_url).hostname or ""
    for pat in FORBIDDEN_HOST_PATTERNS:
        if re.search(pat, host):
            raise SystemExit(f"refusing to drive production host {host!r}; this harness is dev-rig only")
    return base_url.rstrip("/")


def out_dir(args):
    d = args.out_dir or os.path.expanduser(
        f"~/sources/tmp/ui-sluggishness-{TASK_ID}-{os.getpid()}"
    )
    os.makedirs(d, exist_ok=True)
    return d


class CDP:
    def __init__(self, cdp="127.0.0.1:9222"):
        v = json.load(urllib.request.urlopen(f"http://{cdp}/json/version"))
        # headless-shell advertises ws://127.0.0.1/...; dial the host we were given.
        ws_url = re.sub(r"^ws://[^/]+", f"ws://{cdp}", v["webSocketDebuggerUrl"])
        self.ws = websocket.create_connection(ws_url, timeout=60, suppress_origin=True)
        self.i = 0
        self.sid = None
        self.ctx = None
        self.events = []

    def send(self, method, params=None, session=True):
        self.i += 1
        mid = self.i
        msg = {"id": mid, "method": method, "params": params or {}}
        if session and self.sid:
            msg["sessionId"] = self.sid
        self.ws.send(json.dumps(msg))
        while True:
            r = json.loads(self.ws.recv())
            if r.get("id") == mid:
                if "error" in r:
                    raise RuntimeError(f"{method}: {r['error']}")
                return r.get("result", {})
            self.events.append(r)

    def js(self, expr):
        r = self.send(
            "Runtime.evaluate",
            {"expression": expr, "returnByValue": True, "awaitPromise": True},
        )
        return r.get("result", {}).get("value")

    def open_page(self, width=1440, height=900):
        """Create a private browser context + page, attach, enable domains."""
        self.ctx = self.send(
            "Target.createBrowserContext", {"disposeOnDetach": True}, session=False
        )["browserContextId"]
        tid = self.send(
            "Target.createTarget",
            {"url": "about:blank", "browserContextId": self.ctx},
            session=False,
        )["targetId"]
        self.sid = self.send(
            "Target.attachToTarget", {"targetId": tid, "flatten": True}, session=False
        )["sessionId"]
        self.tid = tid
        for d in ["Page.enable", "Runtime.enable", "Network.enable", "Performance.enable"]:
            self.send(d)
        self.send(
            "Emulation.setDeviceMetricsOverride",
            {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": width < 768},
        )
        self.send("Page.addScriptToEvaluateOnNewDocument", {"source": LONGTASK_OBSERVER})
        return self.ctx

    def close(self):
        if self.ctx:
            try:
                self.send("Target.disposeBrowserContext", {"browserContextId": self.ctx}, session=False)
            except Exception:
                pass
        self.ws.close()

    def drain(self, sec):
        """Read every CDP message for `sec` seconds (never leave frames unread)."""
        end = time.time() + sec
        self.ws.settimeout(0.25)
        while time.time() < end:
            try:
                self.events.append(json.loads(self.ws.recv()))
            except websocket.WebSocketTimeoutException:
                pass
        self.ws.settimeout(60)

    def goto(self, url, wait=4):
        self.send("Page.navigate", {"url": url})
        self.drain(wait)

    def login(self, base_url, as_slug=None):
        q = f"?as={urllib.parse.quote(as_slug)}" if as_slug else ""
        self.goto(f"{base_url}/dev/login{q}", 4)

    def where(self):
        return self.js("location.pathname + location.search") or "?"

    def live_ok(self):
        return self.js(
            "typeof window.liveSocket !== 'undefined' && window.liveSocket.isConnected()"
        )

    def nodes(self):
        return self.js("document.getElementsByTagName('*').length")

    def take_longtasks(self):
        lt = self.js("(()=>{const l=window.__lt||[];window.__lt=[];return l})()") or []
        return lt

    def ws_frames(self, direction="received"):
        method = "Network.webSocketFrameReceived" if direction == "received" else "Network.webSocketFrameSent"
        out = []
        for e in self.events:
            if e.get("method") == method:
                out.append(e["params"]["response"]["payloadData"])
        return out

    def cid_names(self):
        return (
            self.js(
                "Object.fromEntries([...document.querySelectorAll('[data-phx-component]')]"
                ".map(e=>[e.getAttribute('data-phx-component'),"
                "e.id||e.getAttribute('data-role')||(e.className||'').toString().split(' ')[0]||e.tagName]))"
            )
            or {}
        )


def _size(obj):
    return len(json.dumps(obj, separators=(",", ":")).encode())


def _diffs(payload_text):
    """Yield the rendered diff(s) inside one LiveView frame."""
    try:
        msg = json.loads(payload_text)
    except ValueError:
        return []
    if not isinstance(msg, list) or len(msg) != 5:
        return []
    event, payload = msg[3], msg[4]
    if not isinstance(payload, dict):
        return []
    if event == "diff":
        return [payload]
    if event == "phx_reply":
        resp = payload.get("response") or {}
        out = []
        for k in ("diff", "rendered"):
            if isinstance(resp.get(k), dict):
                out.append(resp[k])
        return out
    return []


def attribute(frames, names=None):
    """Sum serialized size per component cid and per root key across frames."""
    names = names or {}
    totals = {}
    for text in frames:
        for diff in _diffs(text):
            for key, val in diff.items():
                if key == "c" and isinstance(val, dict):
                    for cid, cdiff in val.items():
                        label = f"cid {cid} ({names.get(str(cid), '?')})"
                        totals[label] = totals.get(label, 0) + _size(cdiff)
                else:
                    label = f"root {key}"
                    totals[label] = totals.get(label, 0) + _size(val)
    return sorted(totals.items(), key=lambda kv: -kv[1])


def frame_sizes(frames):
    return [len(f.encode()) for f in frames]


def kb(n):
    return round(n / 1024, 1)


def fmt_top(top, n=5):
    return "; ".join(f"{k}={kb(v)}KB" for k, v in top[:n])


def heaviest_path(frames, start_key, depth=5, width=4):
    """Walk the heaviest branch of `start_key` ("c/<cid>" or a root key) across frames.

    Returns a list of levels; each level is the `width` largest child keys with
    sizes, and the walk descends into the largest one. This is how a "cid 3 is
    70 KB" row becomes "cid 3 > 2 > d (the card comprehension) is 68 KB".
    """
    merged = []
    for text in frames:
        for diff in _diffs(text):
            node = diff
            ok = True
            for part in start_key.split("/"):
                if isinstance(node, dict) and part in node:
                    node = node[part]
                else:
                    ok = False
                    break
            if ok:
                merged.append(node)
    levels = []
    path = start_key
    nodes = merged
    for _ in range(depth):
        sizes = {}
        nxt = {}
        for n in nodes:
            items = n.items() if isinstance(n, dict) else enumerate(n) if isinstance(n, list) else []
            for k, v in items:
                k = str(k)
                sizes[k] = sizes.get(k, 0) + _size(v)
                nxt.setdefault(k, []).append(v)
        if not sizes:
            break
        top = sorted(sizes.items(), key=lambda kv: -kv[1])[:width]
        levels.append({"path": path, "children": top, "child_count": len(sizes)})
        k0 = top[0][0]
        path = f"{path}/{k0}"
        nodes = nxt[k0]
    return levels


class CpuProfile:
    """Sampling JS profile around one action (Profiler domain)."""

    def __init__(self, c, interval_us=200):
        self.c = c
        c.send("Profiler.enable")
        c.send("Profiler.setSamplingInterval", {"interval": interval_us})

    def start(self):
        self.c.send("Profiler.start")

    def stop(self, top=8):
        prof = self.c.send("Profiler.stop")["profile"]
        by_id = {n["id"]: n for n in prof["nodes"]}
        self_us = {}
        for sid, dt in zip(prof.get("samples", []), prof.get("timeDeltas", [])):
            n = by_id.get(sid)
            if not n:
                continue
            cf = n["callFrame"]
            name = cf.get("functionName") or "(anonymous)"
            url = (cf.get("url") or "").rsplit("/", 1)[-1].split("?")[0]
            key = f"{name} {url}:{cf.get('lineNumber', 0) + 1}" if url else name
            self_us[key] = self_us.get(key, 0) + dt
        idle = self_us.pop("(idle)", 0)
        total = sum(self_us.values())
        ranked = sorted(self_us.items(), key=lambda kv: -kv[1])[:top]
        return {
            "busy_ms": round(total / 1000),
            "idle_ms": round(idle / 1000),
            "top_self_ms": [(k, round(v / 1000, 1)) for k, v in ranked],
        }
