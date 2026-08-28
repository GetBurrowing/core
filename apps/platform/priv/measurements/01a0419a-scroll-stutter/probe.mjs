import { http, Conn, sleep } from "./cdp.mjs";
import fs from "node:fs";

const PORT = process.env.SPORT || "4021";
const SPACE = process.env.SPACE_ID;
const W = parseInt(process.env.VW || "1440", 10);
const H = parseInt(process.env.VH || "900", 10);
const OUT = process.env.OUT || "/Users/rock/Dev/tmp/01a0419a-s2/probe.json";
const MOBILE = W < 768;

const ver = await http("/json/version");
const browser = await new Conn(ver.webSocketDebuggerUrl).open();

const { browserContextId } = await browser.send("Target.createBrowserContext", {
  disposeOnDetach: false,
});
const { targetId } = await browser.send("Target.createTarget", {
  url: "about:blank",
  browserContextId,
  width: W,
  height: H,
});
const { sessionId } = await browser.send("Target.attachToTarget", {
  targetId,
  flatten: true,
});
const S = (m, p) => browser.send(m, p, sessionId);

await S("Page.enable");
await S("Runtime.enable");
await S("Input.enable", {}).catch(() => {});
await S("Emulation.setDeviceMetricsOverride", {
  width: W,
  height: H,
  deviceScaleFactor: 1,
  mobile: MOBILE,
  screenWidth: W,
  screenHeight: H,
});
if (MOBILE)
  await S("Emulation.setTouchEmulationEnabled", {
    enabled: true,
    maxTouchPoints: 5,
  }).catch(() => {});

async function nav(url) {
  await S("Page.navigate", { url });
  for (let i = 0; i < 100; i++) {
    await sleep(200);
    const r = await S("Runtime.evaluate", {
      expression: "document.readyState",
      returnByValue: true,
    });
    if (r.result.value === "complete") break;
  }
}
const evalp = async (expr) => {
  const r = await S("Runtime.evaluate", {
    expression: expr,
    returnByValue: true,
    awaitPromise: true,
  });
  if (r.exceptionDetails)
    throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 600));
  return r.result.value;
};

await nav(`http://localhost:${PORT}/dev/login`);
await sleep(1500);
await nav(`http://localhost:${PORT}/chat/${SPACE}`);
await sleep(3000);

// --- fixture + liveview readiness, read back from the live DOM ---
const ready = await evalp(`(() => {
  const el = document.getElementById("chat-message-scroller");
  return {
    url: location.href,
    scroller: !!el,
    rows: el ? el.querySelectorAll("[data-message-id]").length : 0,
    scrollHeight: el ? el.scrollHeight : null,
    clientHeight: el ? el.clientHeight : null,
    scrollTop: el ? el.scrollTop : null,
    liveSocketConnected: !!(window.liveSocket && window.liveSocket.isConnected()),
    phxMain: !!document.querySelector("[data-phx-main]"),
    bodyClass: document.body.className,
    firstText: el ? (el.querySelector("[data-message-id]")?.innerText || "").slice(0,60) : null,
    lastText: el ? ([...el.querySelectorAll("[data-message-id]")].pop()?.innerText || "").slice(0,60) : null,
  };
})()`);
console.log("READY", JSON.stringify(ready));
if (!ready.scroller) {
  fs.writeFileSync(
    OUT,
    JSON.stringify({ error: "no scroller", ready }, null, 2),
  );
  process.exit(2);
}
if (!ready.liveSocketConnected) {
  fs.writeFileSync(
    OUT,
    JSON.stringify({ error: "livesocket not connected", ready }, null, 2),
  );
  process.exit(3);
}

// --- install recorder: per-rAF post-frame sample + raw scroll-event sample ---
await evalp(`(() => {
  const el = document.getElementById("chat-message-scroller");
  el.scrollTop = el.scrollHeight;             // start at the live edge
  window.__rec = { frames: [], scrollEvents: [], t0: performance.now(), on: false };
  const r = window.__rec;
  el.addEventListener("scroll", () => {
    if (r.on) r.scrollEvents.push([performance.now() - r.t0, el.scrollTop]);
  }, { passive: true });
  const loop = () => {
    if (r.on) r.frames.push([performance.now() - r.t0, el.scrollTop, el.scrollHeight, el.clientHeight]);
    r.raf = requestAnimationFrame(loop);
  };
  loop();
  return true;
})()`);
await sleep(800);
await evalp(
  `(() => { const el=document.getElementById("chat-message-scroller"); el.scrollTop = el.scrollHeight; window.__rec.t0 = performance.now(); window.__rec.on = true; return el.scrollTop; })()`,
);

// --- drive one continuous upward wheel gesture through BOTH thresholds ---
const cx = Math.floor(W / 2),
  cy = Math.floor(H / 2);
const TICKS = 220,
  DELTA = -30,
  GAP = 10;
for (let i = 0; i < TICKS; i++) {
  await S("Input.dispatchMouseEvent", {
    type: "mouseWheel",
    x: cx,
    y: cy,
    deltaX: 0,
    deltaY: DELTA,
    pointerType: "mouse",
    modifiers: 0,
  });
  await sleep(GAP);
}
await sleep(700);
const rec =
  await evalp(`(() => { const r = window.__rec; r.on = false; cancelAnimationFrame(r.raf);
  const el = document.getElementById("chat-message-scroller");
  return { frames: r.frames, scrollEvents: r.scrollEvents, final: { scrollTop: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight } }; })()`);

fs.writeFileSync(
  OUT,
  JSON.stringify({ viewport: { W, H }, ready, ...rec }, null, 2),
);
console.log(
  "FRAMES",
  rec.frames.length,
  "SCROLLEVENTS",
  rec.scrollEvents.length,
  "final",
  JSON.stringify(rec.final),
);
await browser.send("Target.closeTarget", { targetId });
await browser.send("Target.disposeBrowserContext", { browserContextId });
browser.close();
process.exit(0);
