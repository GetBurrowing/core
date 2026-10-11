#!/usr/bin/env python3
"""Capturing reverse proxy in front of a Burrow push relay (dev rig only).

Task 01a1261e stage 2. Python 3 standard library only.

Installs point PUSH_RELAY_URL at this proxy. Every request body is appended,
one compact JSON object per line, to --record (JSONL), then forwarded
unchanged to --upstream (the relay R) with its Authorization and
Content-Type headers; the relay's status and body go back to the caller.

The record is what the review greps for sentinels: it must hold only the
allow-listed item keys and sealed blobs, never a title, body, author or
space name.

    python3 capture_proxy.py --listen 127.0.0.1:4100 \\
        --upstream http://127.0.0.1:4000 --record /path/to/relay-capture.jsonl

Secrets: the bearer credential is forwarded but never written to the record
or printed. stdout names method, path and status only. Never point this at
a production relay.
"""

import argparse
import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FORWARDED_HEADERS = ("Authorization", "Content-Type", "Accept")


def make_handler(upstream, record_path, lock):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 (http.server naming)
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            self._record(raw)
            self._forward("POST", raw)

        def do_GET(self):  # noqa: N802
            self._forward("GET", None)

        def _record(self, raw):
            try:
                line = json.dumps(json.loads(raw.decode("utf-8")), separators=(",", ":"))
            except (UnicodeDecodeError, ValueError):
                line = json.dumps({"unparsed_body": raw.decode("utf-8", "replace")})
            with lock, open(record_path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")

        def _forward(self, method, raw):
            headers = {h: self.headers[h] for h in FORWARDED_HEADERS if self.headers.get(h)}
            req = urllib.request.Request(
                upstream.rstrip("/") + self.path, data=raw, headers=headers, method=method
            )
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    status, body, ctype = resp.status, resp.read(), resp.headers.get("Content-Type")
            except urllib.error.HTTPError as err:
                status, body, ctype = err.code, err.read(), err.headers.get("Content-Type")
            except (urllib.error.URLError, OSError):
                status, body, ctype = 502, b'{"error":"upstream_unreachable"}', "application/json"

            self.send_response(status)
            self.send_header("Content-Type", ctype or "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            # Method, path and status only: never headers or bodies.
            sys.stdout.write("%s %s -> %s\n" % (self.command, self.path, args[1] if len(args) > 1 else "?"))
            sys.stdout.flush()

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--listen", default="127.0.0.1:4100", help="host:port to listen on")
    parser.add_argument("--upstream", required=True, help="relay base url, e.g. http://127.0.0.1:4000")
    parser.add_argument("--record", required=True, help="JSONL file each request body is appended to")
    args = parser.parse_args()

    host, _, port = args.listen.rpartition(":")
    server = ThreadingHTTPServer((host or "127.0.0.1", int(port)), make_handler(args.upstream, args.record, threading.Lock()))
    sys.stdout.write("capture proxy on %s -> %s, recording to %s\n" % (args.listen, args.upstream, args.record))
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
