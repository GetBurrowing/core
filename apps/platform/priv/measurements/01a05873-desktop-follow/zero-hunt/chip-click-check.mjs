// Gate-3 semantics check: a reader 600px above the live edge receives a
// message -> the jump chip appears (the two-threshold rule: shallow + new
// message); clicking it returns them to the live edge and drops the chip.
import { Conn, sleep } from
  "/home/dev/sources/worktrees/01a05873-c623-7001-97d3-e81a22073650/apps/platform/priv/measurements/01a05873-desktop-follow/cdp.mjs";

const APP = "http://192.0.2.200:4012";
const CHAT = `${APP}/chat/follow-probe`;
const ver = await fetch("http://127.0.0.1:9224/json/version").then(r => r.json());
const browser = await new Conn(ver.webSocketDebuggerUrl).open();

async function mkSession(W, H, slug) {
  const { browserContextId } = await browser.send("Target.createBrowserContext", { disposeOnDetach: false });
  const { targetId } = await browser.send("Target.createTarget", { url: "about:blank", browserContextId, width: W, height: H });
  const { sessionId } = await browser.send("Target.attachToTarget", { targetId, flatten: true });
  const S = (m, p) => browser.send(m, p, sessionId);
  await S("Page.enable");
  await S("Runtime.enable");
  await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false, screenWidth: W, screenHeight: H });
  const evalp = async (e) => {
    const r = await S("Runtime.evaluate", { expression: e, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || "eval");
    return r.result.value;
  };
  return { S, evalp };
}
const until = async (evalp, expr, timeoutMs = 30000, everyMs = 200, label = expr) => {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) { last = await evalp(expr); if (last) return last; await sleep(everyMs); }
  throw new Error("timeout: " + label + " last=" + JSON.stringify(last)?.slice(0, 200));
};

const out = { fatal: null };
try {
  const reader = await mkSession(1440, 900, "reader");
  const sender = await mkSession(1440, 900, "sender");
  await reader.S("Page.navigate", { url: `${APP}/dev/login?as=reader` });
  await sender.S("Page.navigate", { url: `${APP}/dev/login?as=sender` });
  await sleep(2200);
  await reader.S("Page.navigate", { url: CHAT });
  await sender.S("Page.navigate", { url: CHAT });
  await until(reader.evalp, `!!(window.liveSocket && document.getElementById("chat-message-scroller"))`, 30000);
  await until(reader.evalp, `(() => { for (const v of Object.values(window.liveSocket.roots||{})) { for (const h of Object.values(v.viewHooks||{})) { if (h && h.el && h.el.id === "message-list") return !h._initialScroll; } } return false; })()`, 30000, 300, "arrival end");
  await until(sender.evalp, `!!(window.liveSocket && document.getElementById("compose-form"))`, 30000, 250, "sender composer");
  await reader.evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); sc.scrollTop = sc.scrollHeight; return 1; })()`);
  await sleep(700);

  // Reader parks 600px above the live edge — a REAL scroll (events fire).
  await reader.evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); sc.scrollTop = sc.scrollHeight - sc.clientHeight - 600; return 1; })()`);
  await sleep(500);
  out.reader600 = await reader.evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); return { d: Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight), chip: !!document.querySelector(".chat-jump-chip") }; })()`);

  // Sender posts one message.
  await sender.evalp(`(() => { const ta = document.querySelector("#compose-form textarea"); ta.focus(); ta.value = "chip-click probe " + Date.now(); ta.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true })); return 1; })()`);
  await sleep(300);
  await sender.evalp(`(() => { const f = document.getElementById("compose-form"); f.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })); return 1; })()`);
  // The arrival must raise the chip for the 600px-up reader.
  await until(reader.evalp, `!!document.querySelector(".chat-jump-chip")`, 20000, 200, "chip appears");
  out.afterArrival = await reader.evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); return { d: Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight), chip: !!document.querySelector(".chat-jump-chip"), rows: document.querySelectorAll("#message-list [data-message-id]").length }; })()`);

  // Click the chip (real element click).
  await reader.evalp(`(() => { document.querySelector(".chat-jump-chip").click(); return 1; })()`);
  await sleep(800);
  out.afterClick = await reader.evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); return { d: Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight), chip: !!document.querySelector(".chat-jump-chip") }; })()`);

  out.verdict =
    out.reader600.chip === false &&
    out.afterArrival.chip === true &&
    out.afterClick.chip === false &&
    out.afterClick.d <= 150
      ? "PASS" : "FAIL";
} catch (e) {
  out.fatal = String(e && e.message ? e.message : e).slice(0, 1000);
}
console.log(JSON.stringify(out, null, 1));
browser.close();
process.exit(out.fatal ? 1 : 0);
