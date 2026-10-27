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
/**
 * A one-direction link shaper: serialization at `bps` bits/s (a shared FIFO,
 * so back-to-back chunks queue behind each other) plus a fixed one-way delay.
 * deliver() runs at (queue-start + bytes/bps + owdMs). bps = 0 means no
 * bandwidth cap. Ordering is preserved because departures are monotone and
 * the one-way delay is constant. Not modelled: TCP slow start, loss.
 * The proxy shapes only the /live websocket connection: page and asset loads
 * (multi-MB unminified dev JS) would otherwise hold the pipe and push
 * LiveView onto long-poll, which is a fault of the rig, not a tab switch.
 */
export function makeLink({ bps = 0, owdMs = 0 } = {}) {
  let free = 0;
  // A single ordered queue drained by one timer. Separate setTimeout calls
  // can fire out of order when their delays differ by under a millisecond
  // (Node truncates them), which reorders bytes on a TCP stream.
  const queue = [];
  let timer = null;
  const pump = () => {
    timer = null;
    const now = performance.now();
    while (queue.length && queue[0].at <= now) queue.shift().deliver();
    if (queue.length) timer = setTimeout(pump, Math.max(0, queue[0].at - performance.now()));
  };
  return {
    send(bytes, deliver) {
      const now = performance.now();
      const start = Math.max(now, free);
      free = start + (bps ? (bytes * 8 * 1000) / bps : 0);
      const at = free + owdMs;
      queue.push({ at, deliver });
      if (timer == null) timer = setTimeout(pump, Math.max(0, at - now));
      return at - now;
    },
  };
}

/** Chrome's CDP Network.emulateNetworkConditions params for a profile. */
export function cdpConditions({ downBps, upBps, rttMs }) {
  return { offline: false, latency: rttMs, downloadThroughput: downBps / 8, uploadThroughput: upBps / 8 };
}

export const PROFILES = {
  "4g": { downBps: 9_000_000, upBps: 1_500_000, rttMs: 85 },
};

export function startByteProxy({ listenPort, targetHost = "127.0.0.1", targetPort, shape = null }) {
  const log = [];
  // One shared link per direction: every connection competes for the same
  // pipe, as on a real access link.
  const downLink = shape ? makeLink({ bps: shape.downBps, owdMs: shape.rttMs / 2 }) : null;
  const upLink = shape ? makeLink({ bps: shape.upBps, owdMs: shape.rttMs / 2 }) : null;
  const conns = new Map();
  let nextId = 1;
  // Server -> client WebSocket MESSAGES on the /live connections, with their
  // wire size and delivery time, decompressed so a frame CDP reports (as
  // text) can be matched to the bytes the link carried for it.
  const messages = [];
  let decoding = Promise.resolve();

  const readDown = (info, chunk, t) => {
    if (!info.reader) {
      // Skip the HTTP 101 response head; frames start after it.
      info.head = info.head ? Buffer.concat([info.head, chunk]) : Buffer.from(chunk);
      const end = info.head.indexOf("\r\n\r\n");
      if (end < 0) return;
      const rest = info.head.subarray(end + 4);
      info.head = null;
      info.reader = new WsMessageReader();
      info.inflater = info.deflateAccepted ? createInflater() : null;
      chunk = rest;
      if (chunk.length === 0) return;
    }
    for (const m of info.reader.push(chunk)) {
      if (m.opcode !== 1 && m.opcode !== 2) continue;
      const rec = { conn: info.id, t, wireBytes: m.wireBytes, rsv1: m.rsv1, text: null };
      messages.push(rec);
      const decode = m.rsv1 && info.inflater ? info.inflater.inflate(m.payload) : Promise.resolve(m.payload);
      decoding = decoding.then(() => decode.then((b) => (rec.text = b.toString("utf8"))).catch(() => (rec.text = null)));
    }
  };

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
      if (upLink && info.ws) {
        upLink.send(chunk.length, () => {
          log.push({ conn: id, dir: "up", bytes: chunk.length, t: performance.now() });
          upstream.write(chunk);
        });
      } else {
        log.push({ conn: id, dir: "up", bytes: chunk.length, t: performance.now() });
        upstream.write(chunk);
      }
    });
    upstream.on("data", (chunk) => {
      if (info.ws && info.upgradeStatus === undefined) {
        const head = chunk.subarray(0, 2048).toString("latin1");
        info.upgradeStatus = head.split("\r\n", 1)[0];
        if (head.startsWith("HTTP/1.1 101")) {
          info.deflateAccepted = /sec-websocket-extensions:[^\r\n]*permessage-deflate/i.test(head);
        }
      }
      // Shaped: the byte is logged when it reaches the client, so a window
      // sum is what the browser had received by then.
      if (downLink && info.ws) {
        downLink.send(chunk.length, () => {
          const t = performance.now();
          log.push({ conn: id, dir: "down", bytes: chunk.length, t });
          readDown(info, chunk, t);
          if (!client.destroyed) client.write(chunk);
        });
      } else {
        const t = performance.now();
        log.push({ conn: id, dir: "down", bytes: chunk.length, t });
        if (info.ws) readDown(info, chunk, t);
        client.write(chunk);
      }
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
        messages,
        /** Resolves once every message seen so far is decompressed. */
        settled: () => decoding,
        /** Wire bytes of the server message whose text is `text`, delivered in [t0, t1]. */
        async wireBytesFor(text, t0 = -Infinity, t1 = Infinity) {
          await decoding;
          return wireBytesForText(messages, text, t0, t1);
        },
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

/**
 * Sum of main-thread trace event durations by name. The main thread is the
 * pid:tid with the most RunTask time.

// Events nest (FunctionCall inside EventDispatch inside RunTask), so the
// names are NOT additive; each is that event type's own total.
export function traceBreakdown(events) {
  const tasks = new Map();
  for (const e of events) if (e.name === "RunTask" && e.ph === "X") tasks.set(`${e.pid}:${e.tid}`, (tasks.get(`${e.pid}:${e.tid}`) || 0) + e.dur);
  const main = [...tasks.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
  const out = {};
  for (const e of events) {
    if (e.ph !== "X" || `${e.pid}:${e.tid}` !== main) continue;
    out[e.name] = (out[e.name] || 0) + e.dur / 1000;
  }
  const keep = ["RunTask", "EventDispatch", "FunctionCall", "EvaluateScript", "v8.compile", "TimerFire", "FireAnimationFrame", "UpdateLayoutTree", "Layout", "PrePaint", "Paint", "Layerize", "Commit", "ParseHTML", "MinorGC", "MajorGC", "V8.GC_MC_BACKGROUND_MARKING"];
  return Object.fromEntries(keep.filter((k) => out[k] != null).map((k) => [k, out[k]]));
}


/**
 * Sum of main-thread trace event durations by name, in ms. The main thread is
 * the pid:tid with the most RunTask time. Events nest (FunctionCall inside
 * EventDispatch inside RunTask), so the names are NOT additive: each is that
 * event type's own total.
 */
export function traceBreakdown(events) {
  const tasks = new Map();
  for (const e of events) if (e.name === "RunTask" && e.ph === "X") tasks.set(`${e.pid}:${e.tid}`, (tasks.get(`${e.pid}:${e.tid}`) || 0) + e.dur);
  const main = [...tasks.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
  const out = {};
  for (const e of events) {
    if (e.ph !== "X" || `${e.pid}:${e.tid}` !== main) continue;
    out[e.name] = (out[e.name] || 0) + e.dur / 1000;
  }
  const keep = ["RunTask", "EventDispatch", "FunctionCall", "EvaluateScript", "v8.compile", "TimerFire", "FireAnimationFrame", "UpdateLayoutTree", "Layout", "PrePaint", "Paint", "Layerize", "Commit", "ParseHTML", "MinorGC", "MajorGC"];
  return Object.fromEntries(keep.filter((k) => out[k] != null).map((k) => [k, out[k]]));
}

// ── WebSocket frames on the wire (first-frame bytes, task 01a17bf4) ────────

/**
 * Incremental RFC 6455 frame reader for one direction of one connection.
 * push(chunk) returns every MESSAGE completed by that chunk:
 * `{opcode, rsv1, wireBytes, payload}` where wireBytes is the frame headers
 * plus payloads of every frame of the message (what the link carried) and
 * payload is the concatenated (still compressed when rsv1) payload. Control
 * frames (ping/pong/close) are returned as their own messages. Masked frames
 * (client -> server) are unmasked.
 */
export class WsMessageReader {
  constructor() {
    this.buf = Buffer.alloc(0);
    this.partial = null;
  }

  push(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : Buffer.from(chunk);
    const out = [];
    for (;;) {
      const f = readFrame(this.buf);
      if (!f) break;
      this.buf = this.buf.subarray(f.total);
      const control = f.opcode >= 8;
      if (control) {
        out.push({ opcode: f.opcode, rsv1: false, wireBytes: f.total, payload: f.payload });
        continue;
      }
      if (f.opcode !== 0 || !this.partial) {
        this.partial = { opcode: f.opcode, rsv1: f.rsv1, wireBytes: 0, parts: [] };
      }
      this.partial.wireBytes += f.total;
      this.partial.parts.push(f.payload);
      if (f.fin) {
        const m = this.partial;
        this.partial = null;
        out.push({ opcode: m.opcode, rsv1: m.rsv1, wireBytes: m.wireBytes, payload: Buffer.concat(m.parts) });
      }
    }
    return out;
  }
}

function readFrame(buf) {
  if (buf.length < 2) return null;
  const b0 = buf[0];
  const b1 = buf[1];
  let len = b1 & 0x7f;
  let off = 2;
  if (len === 126) {
    if (buf.length < 4) return null;
    len = buf.readUInt16BE(2);
    off = 4;
  } else if (len === 127) {
    if (buf.length < 10) return null;
    len = Number(buf.readBigUInt64BE(2));
    off = 10;
  }
  const masked = (b1 & 0x80) !== 0;
  const maskAt = off;
  if (masked) off += 4;
  if (buf.length < off + len) return null;
  let payload = buf.subarray(off, off + len);
  if (masked) {
    const key = buf.subarray(maskAt, maskAt + 4);
    payload = Buffer.from(payload);
    for (let i = 0; i < payload.length; i++) payload[i] ^= key[i % 4];
  }
  return { fin: (b0 & 0x80) !== 0, rsv1: (b0 & 0x40) !== 0, opcode: b0 & 0x0f, payload, total: off + len };
}

/**
 * permessage-deflate inflater for one direction of one connection. One raw
 * inflate stream for the whole connection, so it reads both context takeover
 * and no-context-takeover senders. Calls are serialized; each resolves to the
 * message's decompressed bytes.
 */
export function createInflater() {
  const inflater = zlib.createInflateRaw({ windowBits: 15 });
  let chunks = [];
  inflater.on("data", (c) => chunks.push(c));
  let chain = Promise.resolve();
  return {
    inflate(payload) {
      const p = chain.then(
        () =>
          new Promise((resolve, reject) => {
            chunks = [];
            inflater.write(Buffer.concat([payload, Buffer.from([0x00, 0x00, 0xff, 0xff])]));
            inflater.flush(zlib.constants.Z_SYNC_FLUSH, (err) => (err ? reject(err) : resolve(Buffer.concat(chunks))));
          }),
      );
      chain = p.catch(() => {});
      return p;
    },
    close: () => inflater.close(),
  };
}

/**
 * Wire bytes of the server message whose decompressed text is exactly
 * `text`, among `messages` (`{text, wireBytes, t}`) delivered in [t0, t1].
 * The LAST match wins (a retransmitted identical frame is not expected, but
 * the newest one is the one this tap received). Null when none matches.
 */
export function wireBytesForText(messages, text, t0 = -Infinity, t1 = Infinity) {
  if (typeof text !== "string") return null;
  let hit = null;
  for (const m of messages) if (m.t >= t0 && m.t <= t1 && m.text === text) hit = m;
  return hit ? hit.wireBytes : null;
}

// ── first-frame sizing (task 01a17bf4) ────────────────────────────────────

/**
 * Number of rows whose box intersects the scroll container's visible box
 * (a positive-area overlap; a row merely touching an edge does not count,
 * and zero-height rows never count). Rects are `{top, bottom}` in the same
 * coordinate space.
 */
export function countVisibleRows(rowRects, viewRect) {
  const top = Math.max(viewRect.top, 0);
  const bottom = viewRect.bottom;
  let n = 0;
  for (const r of rowRects) {
    if (!(r.bottom > r.top)) continue;
    if (r.top < bottom && r.bottom > top) n++;
  }
  return n;
}

/**
 * The first-frame message count: ceil(max visible rows across viewports)
 * plus a buffer, clamped to [min, max]. Throws on no usable counts, so a
 * failed measurement cannot quietly become the floor.
 */
export function pickInitialMessageCount(visibleCounts, { buffer = 3, min = 10, max = 25 } = {}) {
  const xs = visibleCounts.filter((v) => typeof v === "number" && Number.isFinite(v) && v >= 0);
  if (xs.length === 0) throw new Error("no visible-row counts to pick N from");
  const raw = Math.ceil(Math.max(...xs)) + buffer;
  return Math.min(Math.max(raw, min), max);
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
  // The runner's timebox ends the driver with SIGALRM: take our Chrome with
  // it rather than leaving a headless browser on the port.
  for (const sig of ["SIGALRM", "SIGTERM", "SIGINT", "SIGHUP"]) {
    process.once(sig, () => {
      kill();
      process.exit(128 + (os.constants.signals[sig] || 0));
    });
  }
  process.once("exit", kill);

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
