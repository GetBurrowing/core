// Deliberate-top load-older check (tight): a reader who REALLY scrolls to
// the top must (1) trigger load_older_messages, (2) have it captured with
// the reader's TRUE position (_preTop = 0 — the guard must NOT substitute
// for a genuine scroll), and (3) stay anchored on the row they were reading
// after the prepend (scrollTop = 0 + Δ).
import fs from "node:fs";
import { Conn, sleep } from
  "/home/dev/sources/worktrees/01a05873-c623-7001-97d3-e81a22073650/apps/platform/priv/measurements/01a05873-desktop-follow/cdp.mjs";

const ver = await fetch("http://127.0.0.1:9224/json/version").then(r => r.json());
const browser = await new Conn(ver.webSocketDebuggerUrl).open();
const { browserContextId } = await browser.send("Target.createBrowserContext", { disposeOnDetach: false });
const { targetId } = await browser.send("Target.createTarget", { url: "about:blank", browserContextId, width: 1440, height: 900 });
const { sessionId } = await browser.send("Target.attachToTarget", { targetId, flatten: true });
const S = (m, p) => browser.send(m, p, sessionId);
await S("Page.enable");
await S("Runtime.enable");
await S("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false, screenWidth: 1440, screenHeight: 900 });
const evalp = async (e) => {
  const r = await S("Runtime.evaluate", { expression: e, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || "eval");
  return r.result.value;
};
const until = async (expr, timeoutMs = 30000, everyMs = 200, label = expr) => {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) { last = await evalp(expr); if (last) return last; await sleep(everyMs); }
  throw new Error("timeout: " + label + " last=" + JSON.stringify(last)?.slice(0, 200));
};

const out = { fatal: null };
try {
  await S("Page.navigate", { url: `http://192.0.2.200:4012/dev/login?as=reader` });
  await sleep(2000);
  await S("Page.navigate", { url: `http://192.0.2.200:4012/chat/follow-probe` });
  await until(`!!(window.liveSocket && document.getElementById("chat-message-scroller"))`, 30000);
  await until(
    `(() => { for (const v of Object.values(window.liveSocket.roots || {})) { for (const h of Object.values(v.viewHooks || {})) { if (h && h.el && h.el.id === "message-list") return !h._initialScroll; } } return false; })()`,
    30000, 300, "arrival end");
  await evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); sc.scrollTop = sc.scrollHeight; return true; })()`);
  await sleep(600);
  out.baselineRows = await evalp(`document.querySelectorAll("#message-list [data-message-id]").length`);
  out.baselineSh = await evalp(`document.getElementById("chat-message-scroller").scrollHeight`);

  // Instrument the sentinel hook to record what the capture saw.
  out.instrumented = await evalp(`(() => {
    let sent = null;
    for (const v of Object.values(window.liveSocket.roots || {})) {
      for (const h of Object.values(v.viewHooks || {})) {
        if (h && h.el && h.el.id === "chat-scroll-sentinel-top") sent = h;
      }
    }
    if (!sent) return { fatal: "no sentinel hook" };
    window.__sent = sent;
    window.__sentTriggers = [];
    const ot = sent._trigger.bind(sent);
    sent._trigger = function () {
      ot();
      window.__sentTriggers.push({ preTop: this._preTop, preHeight: this._preHeight });
    };
    // Capture the row the reader will be reading at the top (pre-scroll).
    const rows = document.querySelectorAll("#message-list [data-message-id]");
    window.__anchorId = rows[0].dataset.messageId;
    return { ok: true, anchorId: window.__anchorId };
  })()`);
  if (out.instrumented.fatal) throw new Error(out.instrumented.fatal);

  // THE DELIBERATE SCROLL: one real scroll to the very top — a single
  // programmatic write delivers a real scroll event exactly like a jump.
  await evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); sc.scrollTop = 0; return true; })()`);
  await sleep(150);
  await until(`window.__sentTriggers.length >= 1`, 15000, 100, "sentinel trigger");
  await until(`document.querySelectorAll("#message-list [data-message-id]").length >= 100`, 20000, 150, "prepend");
  await sleep(700); // _afterOlder rAF lands

  out.afterRows = await evalp(`document.querySelectorAll("#message-list [data-message-id]").length`);
  out.triggers = await evalp(`window.__sentTriggers`);
  out.geo = await evalp(`(() => {
    const sc = document.getElementById("chat-message-scroller");
    const anchor = document.querySelector('[data-message-id="' + window.__anchorId + '"]');
    const sr = sc.getBoundingClientRect();
    const ar = anchor.getBoundingClientRect();
    return {
      st: Math.round(sc.scrollTop), sh: sc.scrollHeight, ch: sc.clientHeight,
      d: Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight),
      delta: sc.scrollHeight - ${JSON.stringify(out.baselineSh)},
      anchorTopInScroller: Math.round(ar.top - sr.top),
    };
  })()`);
  out.verdict =
    out.afterRows >= 100 &&
    out.triggers.length === 1 &&
    out.triggers[0].preTop === 0 &&          // TRUE position captured (no guard substitution)
    out.triggers[0].preHeight === out.baselineSh &&
    Math.abs(out.geo.anchorTopInScroller) <= 60 &&  // reader anchored on their row
    Math.abs(out.geo.st - out.geo.delta) <= 60      // st = 0 + Δ
      ? "PASS" : "FAIL";
  fs.writeFileSync("/tmp/zero-hunt/top-check-out.json", JSON.stringify(out, null, 1));
} catch (e) {
  out.fatal = String(e && e.message ? e.message : e).slice(0, 1000);
}
console.log(JSON.stringify(out, null, 1));
browser.close();
process.exit(out.fatal ? 1 : 0);
