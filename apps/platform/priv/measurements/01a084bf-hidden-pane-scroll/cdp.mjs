// Minimal CDP driver for probe.html. Node 22+ only: it uses the built-in
// WebSocket and fetch, so this directory needs no npm install and no
// node_modules — the same zero-dependency rule assets/test/ follows.
//
// Usage (see README.md for the browser invocation):
//
//     node cdp.mjs               # probe.html   — does display:none lose it?
//     node cdp.mjs reloc.html    # reloc.html   — does the MOVE lose it?
//
// Resolves the probe relative to THIS FILE rather than an absolute path, so
// nothing about one machine's checkout location gets recorded in the repo.

import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
// Which probe to run, defaulting to the original. Resolved relative to THIS
// FILE rather than an absolute path, so nothing about one machine's checkout
// location gets recorded in the repo.
const probeFile = process.argv[2] || "probe.html";
const probeUrl = pathToFileURL(resolve(here, probeFile)).href;

const base = "http://127.0.0.1:9333";

let list = [];
for (let i = 0; i < 60; i++) {
  try {
    const r = await fetch(base + "/json/list");
    list = await r.json();
    if (list.length) break;
  } catch {}
  await new Promise((r) => setTimeout(r, 250));
}
const page = list.find((t) => t.type === "page");
if (!page) {
  console.error("NO PAGE TARGET — is Chrome running with --remote-debugging-port=9333?");
  process.exit(2);
}

const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0;
const pending = new Map();
ws.addEventListener("message", (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  }
});
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
const send = (method, params = {}) =>
  new Promise((res) => {
    const i = ++id;
    pending.set(i, res);
    ws.send(JSON.stringify({ id: i, method, params }));
  });

await send("Page.enable");
await send("Runtime.enable");
await send("Page.navigate", { url: probeUrl });

let out = null;
for (let i = 0; i < 80; i++) {
  await new Promise((r) => setTimeout(r, 250));
  const r = await send("Runtime.evaluate", {
    expression: "document.getElementById('out') && document.getElementById('out').textContent",
    returnByValue: true,
  });
  const v = r.result && r.result.result && r.result.result.value;
  if (v && v.startsWith("RESULT")) {
    out = v;
    break;
  }
}
console.log(out || "TIMED OUT WITH NO RESULT");
ws.close();
process.exit(0);
