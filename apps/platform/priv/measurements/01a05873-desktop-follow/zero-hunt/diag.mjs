// Driver for the zero-hunt diagnostic. Run from hive with node 22:
//   CDP_HOST=192.0.2.200:9222 APP_HOST=192.0.2.200 SPORT=4012 node diag.mjs
import fs from "node:fs";
import { http, Conn, sleep } from
  "/home/dev/sources/worktrees/01a05873-c623-7001-97d3-e81a22073650/apps/platform/priv/measurements/01a05873-desktop-follow/cdp.mjs";

const PORT = process.env.SPORT || "4012";
const APP_HOST = process.env.APP_HOST || "192.0.2.200";
const CHAT_URL = `http://${APP_HOST}:${PORT}/chat/follow-probe`;
const OUT = process.env.OUT_FILE || "/tmp/zero-hunt/diag-out.json";
const INSTRUMENT = fs.readFileSync("/tmp/zero-hunt/instrument.js", "utf8");

const W = 1440, H = 900;

const http2 = (path) => fetch(`http://${process.env.CDP_HOST || "127.0.0.1:9222"}${path}`).then(r => r.json());

(async () => {
  const ver = await http2("/json/version");
  const browser = await new Conn(ver.webSocketDebuggerUrl).open();
  const { browserContextId } = await browser.send("Target.createBrowserContext", { disposeOnDetach: false });
  const { targetId } = await browser.send("Target.createTarget", { url: "about:blank", browserContextId, width: W, height: H });
  const { sessionId } = await browser.send("Target.attachToTarget", { targetId, flatten: true });
  const S = (m, p) => browser.send(m, p, sessionId);
  await S("Page.enable");
  await S("Runtime.enable");
  await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false, screenWidth: W, screenHeight: H });

  const evalp = async (expression) => {
    const r = await S("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error((r.exceptionDetails.exception?.description || JSON.stringify(r.exceptionDetails)).slice(0, 1500));
    return r.result.value;
  };
  const until = async (expr, timeoutMs = 30000, everyMs = 250, label = expr) => {
    const deadline = Date.now() + timeoutMs;
    let last;
    while (Date.now() < deadline) {
      last = await evalp(expr);
      if (last) return last;
      await sleep(everyMs);
    }
    throw new Error("timeout: " + label + " last=" + JSON.stringify(last)?.slice(0, 200));
  };

  const out = { started: new Date().toISOString(), url: CHAT_URL, fatal: null };
  try {
    // login
    await S("Page.navigate", { url: `http://${APP_HOST}:${PORT}/dev/login?as=reader` });
    await until(`document.readyState === "complete"`, 30000);
    await sleep(500);
    // into chat
    await S("Page.navigate", { url: CHAT_URL });
    await until(`!!(window.liveSocket && document.getElementById("chat-message-scroller"))`, 30000);
    // arrival phase end
    await until(
      `(() => { for (const v of Object.values(window.liveSocket.roots || {})) { for (const h of Object.values(v.viewHooks || {})) { if (h && h.el && h.el.id === "message-list") return !h._initialScroll; } } return false; })()`,
      30000, 300, "arrival end",
    );
    // park at bottom
    let base = await evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); return { st: sc.scrollTop, sh: sc.scrollHeight, ch: sc.clientHeight, d: sc.scrollHeight - sc.scrollTop - sc.clientHeight }; })()`);
    if (base.d > 0) {
      await evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); sc.scrollTop = sc.scrollHeight; return true; })()`);
      await sleep(800);
      base = await evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); return { st: sc.scrollTop, sh: sc.scrollHeight, ch: sc.clientHeight, d: sc.scrollHeight - sc.scrollTop - sc.clientHeight }; })()`);
    }
    out.baseline = base;
    if (base.d > 2) throw new Error("not parked at bottom: " + JSON.stringify(base));

    // install instrumentation
    out.instrumentation = await evalp(INSTRUMENT);
    if (out.instrumentation.fatal) throw new Error("instrumentation fatal");
    await sleep(200);

    // click the toggle with real mouse events
    const rect = await evalp(`(() => { const el = document.querySelector('[phx-click="canvas_panel_toggle"]'); if (!el) return null; const r = el.getBoundingClientRect(); return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) }; })()`);
    if (!rect) throw new Error("no toggle button");
    out.clickAt = rect;
    await S("Input.dispatchMouseEvent", { type: "mouseMoved", x: rect.x, y: rect.y });
    await S("Input.dispatchMouseEvent", { type: "mousePressed", x: rect.x, y: rect.y, button: "left", clickCount: 1 });
    await S("Input.dispatchMouseEvent", { type: "mouseReleased", x: rect.x, y: rect.y, button: "left", clickCount: 1 });

    await sleep(1500);
    out.final = await evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); return { st: sc.scrollTop, sh: sc.scrollHeight, ch: sc.clientHeight, d: Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight), drawerOpen: !!document.getElementById("canvas-sort"), rows: document.querySelectorAll("#message-list [data-message-id]").length, chip: !!document.querySelector(".chat-jump-chip") }; })()`);
    out.events = await evalp(`window.__z.events`);
  } catch (e) {
    out.fatal = String(e && e.message ? e.message : e).slice(0, 2000);
  }
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
  console.log("WROTE", OUT, "fatal:", out.fatal);
  console.log("baseline:", JSON.stringify(out.baseline), "final:", JSON.stringify(out.final));
  browser.close();
  process.exit(0);
})().catch((e) => { console.error("FATAL", e); process.exit(1); });
