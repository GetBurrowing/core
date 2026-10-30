"""Minimal Burrow MCP (Streamable HTTP) client, stdlib only.

Never logs the token, tool arguments or tool results. Callers get parsed JSON.
"""

from __future__ import annotations

import itertools
import json
import os
import urllib.error
import urllib.request

PROTOCOL = "2025-03-26"


class ToolError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class McpClient:
    def __init__(self, base_url: str, token: str, timeout_s: float = 120.0):
        self.url = base_url.rstrip("/") + "/mcp"
        self._token = token
        self.timeout_s = timeout_s
        self.session: str | None = None
        self._ids = itertools.count(1)

    @classmethod
    def from_env(cls) -> McpClient:
        return cls(os.environ["CLIP_RUNNER_BASE_URL"], os.environ["CLIP_RUNNER_TOKEN"])

    def _post(self, body: dict) -> dict | None:
        data = json.dumps(body).encode()
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": f"Bearer {self._token}",
            "MCP-Protocol-Version": PROTOCOL,
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_s) as resp:  # noqa: S310 - https base url
                sid = resp.headers.get("Mcp-Session-Id")
                if sid:
                    self.session = sid
                ctype = resp.headers.get("Content-Type", "")
                raw = resp.read().decode()
        except urllib.error.HTTPError as e:
            if e.code == 404 and self.session:
                self.session = None  # session expired: caller re-initializes
                raise ToolError("MCP_SESSION_EXPIRED") from None
            raise ToolError(f"MCP_HTTP_{e.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ToolError("MCP_UNREACHABLE") from None
        if "id" not in body or not raw.strip():
            return None
        if "text/event-stream" in ctype:
            msg = None
            for line in raw.splitlines():
                if line.startswith("data:"):
                    try:
                        cand = json.loads(line[5:].strip())
                    except ValueError:
                        continue
                    if isinstance(cand, dict) and cand.get("id") == body["id"]:
                        msg = cand
            if msg is None:
                raise ToolError("MCP_NO_RESPONSE")
            return msg
        try:
            return json.loads(raw)
        except ValueError:
            raise ToolError("MCP_BAD_JSON") from None

    def initialize(self) -> None:
        self.session = None
        msg = self._post({"jsonrpc": "2.0", "id": next(self._ids), "method": "initialize", "params": {
            "protocolVersion": PROTOCOL, "capabilities": {},
            "clientInfo": {"name": "clip-runner-moon", "version": "1"}}})
        if not msg or "error" in msg:
            raise ToolError("MCP_INIT_FAILED")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _rpc(self, method: str, params: dict) -> dict:
        if self.session is None:
            self.initialize()
        try:
            msg = self._post({"jsonrpc": "2.0", "id": next(self._ids), "method": method, "params": params})
        except ToolError as e:
            if e.code != "MCP_SESSION_EXPIRED":
                raise
            self.initialize()
            msg = self._post({"jsonrpc": "2.0", "id": next(self._ids), "method": method, "params": params})
        if msg is None:
            raise ToolError("MCP_NO_RESPONSE")
        if "error" in msg:
            raise ToolError(f"MCP_RPC_{(msg['error'] or {}).get('code', 'ERR')}")
        return msg.get("result") or {}

    def list_tools(self) -> list[dict]:
        return self._rpc("tools/list", {}).get("tools", [])

    def call(self, tool: str, args: dict) -> dict:
        """Call a tool; return its JSON result, or raise ToolError(code) on a tool error."""
        result = self._rpc("tools/call", {"name": tool, "arguments": args})
        doc = result.get("structuredContent")
        if doc is None:
            texts = [c.get("text", "") for c in result.get("content") or [] if c.get("type") == "text"]
            text = "".join(texts)
            try:
                doc = json.loads(text) if text.strip() else {}
            except ValueError:
                doc = {"_text": True}
        if result.get("isError"):
            code = None
            if isinstance(doc, dict):
                err = doc.get("error")
                code = doc.get("code") or (err.get("code") if isinstance(err, dict) else None)
            raise ToolError(str(code or "tool_error"))
        if not isinstance(doc, dict):
            doc = {"result": doc}
        return doc
