// Helpers for measure-tab-switch.mjs (task 01a17b00 stage 1).
//
// Kept apart from the driver so the parts that turn raw observations into
// reported numbers (percentiles, LiveView frame parsing, the deflate wire
// estimate, the byte-counting proxy) are unit-tested on their own:
//   node --test e2e/scripts/tab-switch-lib.test.mjs

import net from "node:net";
import zlib from "node:zlib";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// ── statistics ────────────────────────────────────────────────────────────

/** Nearest-rank percentile (p in 0..100) of a numeric list; null when empty. */
export function percentile(values, p) {
  const xs = values.filter((v) => typeof v === "number" && Number.isFinite(v)).sort((a, b) => a - b);
  if (xs.length === 0) return null;
  const rank = Math.ceil((p / 100) * xs.length);
  return xs[Math.min(Math.max(rank, 1), xs.length) - 1];
}

/** Median as the mean of the two middle values for an even count. */
export function median(values) {
  const xs = values.filter((v) => typeof v === "number" && Number.isFinite(v)).sort((a, b) => a - b);
  if (xs.length === 0) return null;
  const mid = Math.floor(xs.length / 2);
  return xs.length % 2 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2;
}

export function summarize(values) {
  const xs = values.filter((v) => typeof v === "number" && Number.isFinite(v));
  return { n: xs.length, median: median(xs), p90: percentile(xs, 90) };
}

// ── LiveView frames ───────────────────────────────────────────────────────

/**
 * Parse a Phoenix V2 serializer text frame:
 * `[join_ref, ref, topic, event, payload]`. Returns null for anything else
 * (binary frames, heartbeats in another shape, garbage).
 */
export function parseFrame(payloadData) {
  if (typeof payloadData !== "string" || payloadData[0] !== "[") return null;
  try {
    const msg = JSON.parse(payloadData);
    if (!Array.isArray(msg) || msg.length !== 5) return null;
    const [joinRef, ref, topic, event, payload] = msg;
    return { joinRef, ref, topic, event, payload };
  } catch {
    return null;
  }
}

/** UTF-8 byte length of a frame payload (CDP hands us the decompressed text). */
export function byteLength(payloadData) {
  return Buffer.byteLength(payloadData ?? "", "utf8");
}

/**
 * From a list of `{dir: "sent"|"recv", data, t}` frames, find the phx_join
 * sent for a `lv:` topic after `since` and its phx_reply. Returns
 * `{topic, joinBytes, replyBytes, replyAt, extraRecvBytes}` where
 * extraRecvBytes counts the other frames received on that topic after the
 * reply (patches, pushes) up to `until`. `topic` pins the join to one
 * LiveView (the new main one) when nested LiveViews join too. Null when no
 * join was seen.
 */
export function joinReply(frames, { since = -Infinity, until = Infinity, topic = null } = {}) {
  let join = null;
  for (const f of frames) {
    if (f.t < since || f.dir !== "sent") continue;
    const m = parseFrame(f.data);
    if (
      m &&
      m.event === "phx_join" &&
      typeof m.topic === "string" &&
      m.topic.startsWith("lv:") &&
      (topic == null || m.topic === topic)
    ) {
      join = { ...m, t: f.t, bytes: byteLength(f.data) };
      break;
    }
  }
  if (!join) return null;

  let reply = null;
  let extra = 0;
  for (const f of frames) {
    if (f.t < join.t || f.t > until || f.dir !== "recv") continue;
    const m = parseFrame(f.data);
    if (!m || m.topic !== join.topic) continue;
    if (!reply && m.event === "phx_reply" && m.ref === join.ref) {
      reply = { t: f.t, bytes: byteLength(f.data), status: m.payload?.status, data: f.data };
    } else if (reply) {
      extra += byteLength(f.data);
    }
  }
  return {
    topic: join.topic,
    joinBytes: join.bytes,
    replyBytes: reply ? reply.bytes : null,
    replyStatus: reply ? reply.status : null,
    replyAt: reply ? reply.t : null,
    replyData: reply ? reply.data : null,
    extraRecvBytes: extra,
  };
}

// ── deflate estimate (exp: TLS, no proxy) ────────────────────────────────

/**
 * Estimate permessage-deflate wire bytes for a sequence of server->client
 * text frames: raw deflate, window bits 15, context takeover (one stream
 * shared across frames), each frame ended with a SYNC flush and its 4-byte
 * 00 00 ff ff tail stripped, as RFC 7692 does. Resolves to per-frame sizes.
 * This is an ESTIMATE: it leaves out WebSocket and TLS framing.
 */
export async function deflateEstimate(payloads) {
  const deflater = zlib.createDeflateRaw({ windowBits: 15 });
  const sizes = [];
  let pending = 0;
  deflater.on("data", (chunk) => (pending += chunk.length));
  for (const p of payloads) {
    pending = 0;
    deflater.write(Buffer.from(p, "utf8"));
    await new Promise((resolve) => deflater.flush(zlib.constants.Z_SYNC_FLUSH, resolve));
    sizes.push(Math.max(pending - 4, 0));
  }
  deflater.close();
  return sizes;
}

/** No-context-takeover variant: every frame deflated alone. */
export function deflateEstimateNoTakeover(payloads) {
  return payloads.map((p) => {
    const buf = zlib.deflateRawSync(Buffer.from(p, "utf8"), { windowBits: 15, finishFlush: zlib.constants.Z_SYNC_FLUSH });
    return Math.max(buf.length - 4, 0);
  });
}

// ── byte-counting TCP proxy ───────────────────────────────────────────────

/**
 * A plain TCP pipe from `listenPort` to `targetHost:targetPort` that records
 * every chunk it forwards: `{conn, dir: "up"|"down", bytes, t}` with `t`
 * from performance.now() of this process. Connections are tagged `ws` once
 * their first upstream chunk is an HTTP Upgrade to the LiveView socket, so a
 * window can be summed for the websocket alone. Bytes counted are TCP payload
 * bytes: WebSocket framing (and deflate, once negotiated) included, TCP/IP
 * headers not.
 */
export function startByteProxy({ listenPort, targetHost = "127.0.0.1", targetPort }) {
  const log = [];
  const conns = new Map();
  let nextId = 1;

  const server = net.createServer((client) => {
    const id = nextId++;
    const info = { id, ws: false, sawFirst: false };
    conns.set(id, info);
    const upstream = net.connect(targetPort, targetHost);

    client.on("data", (chunk) => {
      if (!info.sawFirst) {
        info.sawFirst = true;
        const head = chunk.subarray(0, 2048).toString("latin1");
        info.ws = /^GET \/live\/websocket/.test(head) && /upgrade:\s*websocket/i.test(head);
        info.deflateOffered = /sec-websocket-extensions:[^\r\n]*permessage-deflate/i.test(head);
      }
      log.push({ conn: id, dir: "up", bytes: chunk.length, t: performance.now() });
      upstream.write(chunk);
    });
    upstream.on("data", (chunk) => {
      if (info.ws && info.deflateAccepted === undefined) {
        const head = chunk.subarray(0, 2048).toString("latin1");
        if (head.startsWith("HTTP/1.1 101")) {
          info.deflateAccepted = /sec-websocket-extensions:[^\r\n]*permessage-deflate/i.test(head);
        }
      }
      log.push({ conn: id, dir: "down", bytes: chunk.length, t: performance.now() });
      client.write(chunk);
    });
    const close = () => {
      client.destroy();
      upstream.destroy();
    };
    client.on("error", close);
    upstream.on("error", close);
    client.on("close", close);
    upstream.on("close", close);
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(listenPort, "127.0.0.1", () =>
      resolve({
        port: server.address().port,
        log,
        conns,
        /** Sum bytes in [t0, t1] for direction, websocket connections only by default. */
        sum(t0, t1, dir = "down", wsOnly = true) {
          return sumWindow(log, conns, t0, t1, dir, wsOnly);
        },
        close: () => new Promise((r) => server.close(() => r())),
      }),
    );
  });
}

export function sumWindow(log, conns, t0, t1, dir = "down", wsOnly = true) {
  let total = 0;
  for (const e of log) {
    if (e.t < t0 || e.t > t1 || e.dir !== dir) continue;
    if (wsOnly && !conns.get(e.conn)?.ws) continue;
    total += e.bytes;
  }
  return total;
}

// ── Chrome ────────────────────────────────────────────────────────────────

export const CHROME_BIN =
  process.env.CHROME_BIN || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/**
 * Launch a headless Chrome we own: its own --user-data-dir under the OS tmp
 * dir and its own CDP port. Returns {proc, port, profile, endpoint, kill}.
 * Never attaches to someone else's browser.
 */
export async function launchChrome({ port, headless = true, timeoutMs = 20000 }) {
  const profile = mkdtempSync(path.join(os.tmpdir(), "tab-switch-chrome-"));
  const args = [
    `--remote-debugging-port=${port}`,
    "--remote-debugging-address=127.0.0.1",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-default-apps",
    "--disable-extensions",
    "--mute-audio",
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    ...(headless ? ["--headless=new"] : []),
    "about:blank",
  ];
  const proc = spawn(CHROME_BIN, args, { stdio: ["ignore", "ignore", "pipe"], detached: false });
  let stderr = "";
  proc.stderr.on("data", (d) => (stderr += d.toString()));

  const kill = () => {
    try {
      proc.kill("SIGKILL");
    } catch {}
    try {
      rmSync(profile, { recursive: true, force: true });
    } catch {}
  };

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const host of ["127.0.0.1", "[::1]"]) {
      try {
        const res = await fetch(`http://${host}:${port}/json/version`, { signal: AbortSignal.timeout(1000) });
        if (res.ok) {
          const v = await res.json();
          return { proc, port, profile, endpoint: `http://${host}:${port}`, version: v.Browser, kill };
        }
      } catch {}
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  kill();
  throw new Error(`Chrome did not open CDP on ${port} within ${timeoutMs}ms: ${stderr.slice(-400)}`);
}
