"""A hostile "install" for the web install switcher rig (task 01a1ccd4 stage 4).

Listens on four loopback ports, each a distinct origin d.localhost:<port>,
and answers `/api/switcher/unread` badly on purpose. Every answer is CORS
readable by the caller's Origin, so the switcher sees exactly the body.

  4204  text/html with a script tag and an <img onerror> (not JSON)
  4205  a 5 MB JSON body
  4206  a valid count plus extra fields (name, id, html, a nested object)
  4207  a valid count after a 30 s delay

`GET /` on any port serves a page whose script tries a cross-origin read of
another install's unread with a badge key it is given in the query string,
for the "can another origin read it" check. Requests are logged to stdout
with their Origin, Referer and Cookie headers, so a rig walk can show what
the switcher sent.

Test rig only: binds 127.0.0.1, no real hostnames.
"""

import http.server
import json
import socketserver
import sys
import threading
import time

PORTS = {4204: "html", 4205: "huge", 4206: "extra", 4207: "slow"}

PROBE_PAGE = """<!doctype html><meta charset=utf-8><title>D probe</title>
<pre id=out>running</pre>
<script>
const q = new URLSearchParams(location.search)
const target = q.get("target"), key = q.get("key")
const out = document.getElementById("out")
const results = {}
async function probe(path) {
  try {
    const r = await fetch(target + path, {headers: {Authorization: "Bearer " + key}, credentials: "omit"})
    results[path] = {status: r.status, body: (await r.text()).slice(0, 200)}
  } catch (e) {
    results[path] = {error: String(e)}
  }
}
(async () => {
  for (const p of ["/api/switcher/unread", "/api/app/counts", "/api/app/spaces"]) await probe(p)
  out.textContent = JSON.stringify(results)
  document.title = "D probe done"
})()
</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    mode = "html"

    def log_message(self, fmt, *args):
        pass

    def _log(self):
        print(
            json.dumps(
                {
                    "port": self.server.server_address[1],
                    "method": self.command,
                    "path": self.path,
                    "origin": self.headers.get("Origin"),
                    "referer": self.headers.get("Referer"),
                    "cookie": self.headers.get("Cookie"),
                    "authorization": bool(self.headers.get("Authorization")),
                }
            ),
            flush=True,
        )

    def _cors(self):
        origin = self.headers.get("Origin")
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "Authorization")
            self.send_header("Access-Control-Allow-Methods", "GET, DELETE")
            self.send_header("Vary", "Origin")

    def do_OPTIONS(self):
        self._log()
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_DELETE(self):
        self._log()
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        self._log()
        if self.path.startswith("/api/switcher/unread"):
            return self._unread()
        if self.path == "/" or self.path.startswith("/?"):
            return self._send(200, "text/html", PROBE_PAGE.encode())
        self._send(404, "text/plain", b"not found")

    def _unread(self):
        mode = self.server.mode
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        if mode == "html":
            body = b"<html><script>alert(1)</script><img src=x onerror=alert(2)>7</html>"
            return self._send(200, "text/html", body)
        if mode == "huge":
            pad = "x" * (5 * 1024 * 1024)
            body = json.dumps({"unread": 5, "as_of": now, "pad": pad}).encode()
            return self._send(200, "application/json", body)
        if mode == "extra":
            body = json.dumps(
                {
                    "unread": 4,
                    "as_of": now,
                    "name": "<img src=x onerror=alert(3)>",
                    "id": "spoofed",
                    "html": "<script>alert(4)</script>",
                    "nested": {"unread": 999},
                }
            ).encode()
            return self._send(200, "application/json", body)
        time.sleep(30)
        body = json.dumps({"unread": 6, "as_of": now}).encode()
        return self._send(200, "application/json", body)

    def _send(self, status, ctype, body):
        try:
            self.send_response(status)
            self._cors()
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(port, mode):
    srv = Server(("127.0.0.1", port), Handler)
    srv.mode = mode
    srv.serve_forever()


if __name__ == "__main__":
    for port, mode in PORTS.items():
        threading.Thread(target=serve, args=(port, mode), daemon=True).start()
    print(json.dumps({"listening": PORTS}), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        sys.exit(0)
