// node --test e2e/scripts/tab-switch-lib.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import zlib from "node:zlib";
import {
  percentile,
  median,
  summarize,
  parseFrame,
  byteLength,
  joinReply,
  deflateEstimate,
  deflateEstimateNoTakeover,
  startByteProxy,
  sumWindow,
} from "./tab-switch-lib.mjs";

test("percentile is nearest-rank and ignores non-numbers", () => {
  const xs = [10, 1, 9, 2, 8, 3, 7, 4, 6, 5];
  assert.equal(percentile(xs, 90), 9);
  assert.equal(percentile(xs, 100), 10);
  assert.equal(percentile(xs, 0), 1);
  assert.equal(percentile([null, undefined, NaN], 50), null);
  assert.equal(percentile([5, null], 90), 5);
});

test("median averages the middle pair for an even count", () => {
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 3, 2]), 2.5);
  assert.equal(median([]), null);
  assert.deepEqual(summarize([1, 2, 3, null]), { n: 3, median: 2, p90: 3 });
});

test("parseFrame reads the V2 array and rejects anything else", () => {
  assert.deepEqual(parseFrame('["4","5","lv:phx-a","phx_reply",{"status":"ok"}]'), {
    joinRef: "4",
    ref: "5",
    topic: "lv:phx-a",
    event: "phx_reply",
    payload: { status: "ok" },
  });
  assert.equal(parseFrame("not json"), null);
  assert.equal(parseFrame('{"a":1}'), null);
  assert.equal(parseFrame('["only","four","items","here"]'), null);
  assert.equal(parseFrame(undefined), null);
});

test("byteLength counts UTF-8 bytes, not UTF-16 units", () => {
  assert.equal(byteLength("abc"), 3);
  assert.equal(byteLength("é"), 2);
  assert.equal(byteLength("👍"), 4);
});

const join = (ref, topic) => JSON.stringify(["1", ref, topic, "phx_join", {}]);
const reply = (ref, topic, body) => JSON.stringify(["1", ref, topic, "phx_reply", { status: "ok", response: body }]);
const diff = (topic, body) => JSON.stringify([null, null, topic, "diff", body]);

test("joinReply pairs the join with its own reply and counts later frames on that topic", () => {
  const frames = [
    { dir: "sent", t: 1, data: join("7", "lv:phx-child") },
    { dir: "sent", t: 2, data: join("9", "lv:phx-main") },
    { dir: "recv", t: 3, data: reply("7", "lv:phx-child", "x".repeat(50)) },
    { dir: "recv", t: 4, data: reply("8", "lv:phx-main", "wrong ref") },
    { dir: "recv", t: 5, data: reply("9", "lv:phx-main", "y".repeat(100)) },
    { dir: "recv", t: 6, data: diff("lv:phx-main", { a: 1 }) },
    { dir: "recv", t: 7, data: diff("lv:phx-other", { a: 1 }) },
  ];

  const main = joinReply(frames, { topic: "lv:phx-main" });
  assert.equal(main.topic, "lv:phx-main");
  assert.equal(main.replyBytes, byteLength(frames[4].data));
  assert.equal(main.replyStatus, "ok");
  // The wrong-ref reply arrived before the real one and is not "after the reply".
  assert.equal(main.extraRecvBytes, byteLength(frames[5].data));

  // Without a topic the first lv: join wins.
  assert.equal(joinReply(frames).topic, "lv:phx-child");
  assert.equal(joinReply(frames, { topic: "lv:phx-none" }), null);
  assert.equal(joinReply([{ dir: "recv", t: 1, data: reply("1", "lv:x", "") }]), null);
});

test("joinReply reports a missing reply as null bytes, not zero", () => {
  const r = joinReply([{ dir: "sent", t: 1, data: join("2", "lv:phx-a") }]);
  assert.equal(r.replyBytes, null);
});

test("deflateEstimate: context takeover makes a repeated frame much cheaper", async () => {
  const frame = JSON.stringify({ rows: Array.from({ length: 200 }, (_, i) => ({ id: i, title: `task ${i % 7}` })) });
  const [first, second] = await deflateEstimate([frame, frame]);
  const [alone1, alone2] = deflateEstimateNoTakeover([frame, frame]);
  assert.ok(first < byteLength(frame) / 3, `first ${first} vs raw ${byteLength(frame)}`);
  assert.equal(alone1, alone2);
  assert.ok(second < alone2 / 4, `second with takeover ${second} vs alone ${alone2}`);
});

test("deflateEstimate output inflates back to the input (the estimate is a real stream)", async () => {
  const frames = ["hello hello hello", "world world", "hello world"];
  const deflater = zlib.createDeflateRaw({ windowBits: 15 });
  const chunks = [];
  deflater.on("data", (c) => chunks.push(c));
  for (const f of frames) {
    deflater.write(f);
    await new Promise((r) => deflater.flush(zlib.constants.Z_SYNC_FLUSH, r));
  }
  const inflated = zlib.inflateRawSync(Buffer.concat(chunks), { finishFlush: zlib.constants.Z_SYNC_FLUSH }).toString();
  assert.equal(inflated, frames.join(""));
  const sizes = await deflateEstimate(frames);
  // Our sizes strip the 4-byte sync tail per frame.
  assert.equal(sizes.reduce((a, b) => a + b, 0), Buffer.concat(chunks).length - 4 * frames.length);
});

test("sumWindow filters by time, direction and websocket tag", () => {
  const conns = new Map([
    [1, { ws: true }],
    [2, { ws: false }],
  ]);
  const log = [
    { conn: 1, dir: "down", bytes: 100, t: 10 },
    { conn: 1, dir: "up", bytes: 5, t: 11 },
    { conn: 2, dir: "down", bytes: 1000, t: 12 },
    { conn: 1, dir: "down", bytes: 50, t: 30 },
  ];
  assert.equal(sumWindow(log, conns, 0, 20), 100);
  assert.equal(sumWindow(log, conns, 0, 20, "up"), 5);
  assert.equal(sumWindow(log, conns, 0, 20, "down", false), 1100);
  assert.equal(sumWindow(log, conns, 0, 40), 150);
});

test("startByteProxy forwards bytes both ways and tags the LiveView websocket", async () => {
  const upstream = net.createServer((s) => s.on("data", (d) => s.write(Buffer.concat([Buffer.from("echo:"), d]))));
  await new Promise((r) => upstream.listen(0, "127.0.0.1", r));
  const proxy = await startByteProxy({ listenPort: 0, targetPort: upstream.address().port });

  const talk = (first) =>
    new Promise((resolve, reject) => {
      const c = net.connect(proxy.port, "127.0.0.1", () => c.write(first));
      c.once("data", (d) => {
        c.end();
        resolve(d.toString());
      });
      c.on("error", reject);
    });

  const t0 = performance.now();
  const wsHello = "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n";
  assert.equal(await talk(wsHello), "echo:" + wsHello);
  assert.equal(await talk("GET /assets/app.js HTTP/1.1\r\n\r\n"), "echo:GET /assets/app.js HTTP/1.1\r\n\r\n");
  const t1 = performance.now();

  const tagged = [...proxy.conns.values()];
  assert.deepEqual(tagged.map((c) => c.ws), [true, false]);
  assert.equal(tagged[0].deflateOffered, true);
  assert.equal(proxy.sum(t0, t1, "up"), Buffer.byteLength(wsHello));
  assert.equal(proxy.sum(t0, t1, "down"), Buffer.byteLength(wsHello) + 5);
  assert.ok(proxy.sum(t0, t1, "down", false) > proxy.sum(t0, t1, "down"));

  await proxy.close();
  await new Promise((r) => upstream.close(r));
});
