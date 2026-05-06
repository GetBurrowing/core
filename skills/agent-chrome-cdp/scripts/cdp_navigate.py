#!/usr/bin/env python3
"""Navigate the agent Chrome to a URL via CDP and print the final URL.

Usage:
    cdp_navigate.py <url> [--port 9222] [--screenshot path.png]

Stdlib-only (urllib for /json/new, raw socket for the WebSocket framing).
For richer driving, prefer Playwright's `connect_over_cdp`.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import struct
import sys
import urllib.parse
import urllib.request


def cdp_request(method: str, path: str, port: int) -> dict:
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode())


def open_target(port: int, url: str) -> dict:
    """PUT /json/new?<url> creates a new target tab pre-navigated to url."""
    encoded = urllib.parse.quote(url, safe="")
    return cdp_request("PUT", f"/json/new?{encoded}", port)


def close_target(port: int, target_id: str) -> None:
    try:
        cdp_request("GET", f"/json/close/{target_id}", port)
    except Exception:
        pass


# Minimal RFC 6455 WebSocket client. Single-frame send/recv, text only.
def ws_connect(ws_url: str) -> socket.socket:
    parsed = urllib.parse.urlparse(ws_url)
    host, port = parsed.hostname, parsed.port or 80
    sock = socket.create_connection((host, port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    handshake = (
        f"GET {parsed.path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(handshake.encode())
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("WebSocket handshake closed early")
        response += chunk
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError(f"WebSocket handshake failed: {response[:200]!r}")
    return sock


def ws_send(sock: socket.socket, payload: str) -> None:
    data = payload.encode("utf-8")
    header = bytearray([0x81])  # FIN + text frame
    mask_bit = 0x80
    length = len(data)
    if length < 126:
        header.append(mask_bit | length)
    elif length < (1 << 16):
        header.append(mask_bit | 126)
        header += struct.pack(">H", length)
    else:
        header.append(mask_bit | 127)
        header += struct.pack(">Q", length)
    mask = os.urandom(4)
    header += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    sock.sendall(bytes(header) + masked)


def ws_recv(sock: socket.socket) -> str:
    def read_exact(n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("WebSocket closed while reading")
            buf += chunk
        return buf

    header = read_exact(2)
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exact(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exact(8))[0]
    return read_exact(length).decode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("--screenshot", help="optional path to save a PNG screenshot")
    args = parser.parse_args()

    target = open_target(args.port, args.url)
    ws_url = target["webSocketDebuggerUrl"]
    target_id = target["id"]
    sock = ws_connect(ws_url)
    msg_id = 0

    try:
        # Enable Page domain so we get Page.loadEventFired notifications.
        msg_id += 1
        ws_send(sock, json.dumps({"id": msg_id, "method": "Page.enable"}))

        # Wait for loadEventFired.
        for _ in range(120):
            event = json.loads(ws_recv(sock))
            if event.get("method") == "Page.loadEventFired":
                break

        # Read the final URL.
        msg_id += 1
        ws_send(
            sock,
            json.dumps(
                {
                    "id": msg_id,
                    "method": "Runtime.evaluate",
                    "params": {"expression": "location.href"},
                }
            ),
        )
        final_url = None
        while final_url is None:
            event = json.loads(ws_recv(sock))
            if event.get("id") == msg_id:
                final_url = event["result"]["result"]["value"]
        print(final_url)

        if args.screenshot:
            msg_id += 1
            ws_send(
                sock,
                json.dumps(
                    {
                        "id": msg_id,
                        "method": "Page.captureScreenshot",
                        "params": {"format": "png", "captureBeyondViewport": True},
                    }
                ),
            )
            png_b64 = None
            while png_b64 is None:
                event = json.loads(ws_recv(sock))
                if event.get("id") == msg_id:
                    png_b64 = event["result"]["data"]
            with open(args.screenshot, "wb") as fh:
                fh.write(base64.b64decode(png_b64))
            print(args.screenshot, file=sys.stderr)
    finally:
        sock.close()
        close_target(args.port, target_id)

    return 0


if __name__ == "__main__":
    sys.exit(main())
