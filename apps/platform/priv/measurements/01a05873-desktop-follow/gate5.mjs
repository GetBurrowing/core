// gate5.mjs — validation 01a05893-b917-7008 (gate 5 of 5), run from HIVE
// against the dev-on-moon BEAM + a podman headless-shell ON MOON.
//
// Spec: reader parked at the bottom, NO new messages. (a) type a long
// multi-line draft so the composer autosizes 33px -> toward its 200px cap;
// (b) open the canvases drawer above the message pane. After each change
// wait 500ms and measure distance-from-bottom on #chat-message-scroller.
//
// Expected: the reader stays pinned to the live edge through both resizes —
// distance stays <= 150px, the newest message stays visible, no
// .chat-jump-chip appears. A fix that broke the #848 viewport observer
// strands the reader above the fold here (both changes shrink the
// scroller's clientHeight under an unchanged scrollTop, which is the exact
// shape _onViewportResize exists for).
//
// Usage:
//   CDP_HOST=192.0.2.200:9222 APP_HOST=192.0.2.200 SPORT=4012 \
//   GIT_LABEL=<sha>-gate5-moon VW=1440 VH=900 node gate5.mjs
import fs from "node:fs";
import { PORT, APP_HOST, SLUG, OUT_DIR, session, until, sleep } from "./lib.mjs";

const W = parseInt(process.env.VW || "1440", 10);
const H = parseInt(process.env.VH || "900", 10);
const GIT_LABEL = process.env.GIT_LABEL || "unknown";
const CHAT = `/chat/${SLUG}`;
const CHAT_URL = `http://${APP_HOST}:${PORT}${CHAT}`;

// Same snapshot shape the earlier review cases measured (probe.mjs), plus
// last-row visibility geometry and the drawer-open marker.
const snapshot = `(() => {
  const sc = document.getElementById("chat-message-scroller");
  const ta = document.querySelector("#compose-form textarea");
  const rows = document.querySelectorAll("#message-list [data-message-id]");
  const last = rows.length ? rows[rows.length - 1] : null;
  const vis = (() => {
    if (!last || !sc) return null;
    const r = last.getBoundingClientRect(), s = sc.getBoundingClientRect();
    return {
      visible: r.bottom <= s.bottom + 1 && r.top >= s.top - 1,
      rowTop: Math.round(r.top), rowBottom: Math.round(r.bottom),
      scTop: Math.round(s.top), scBottom: Math.round(s.bottom),
    };
  })();
  return {
    vw: window.innerWidth, vh: window.innerHeight,
    st: sc ? Math.round(sc.scrollTop) : null,
    sh: sc ? sc.scrollHeight : null,
    ch: sc ? sc.clientHeight : null,
    d: sc ? Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight) : null,
    taH: ta ? Math.round(ta.getBoundingClientRect().height) : null,
    taRows: ta ? ta.value.split("\\n").length : null,
    chip: !!document.querySelector(".chat-jump-chip"),
    rows: rows.length,
    lastRow: last ? (last.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 60) : null,
    lastVisible: vis,
    drawerOpen: !!document.getElementById("canvas-sort"),
    connected: !!(window.liveSocket && window.liveSocket.isConnected()),
  };
})()`;

// Same hook tracer as probe.mjs — records whether the follow snap ran on the
// patches these two changes cause (composer phx-change, drawer toggle).
const INSTRUMENT = `(() => {
  const ls = window.liveSocket;
  if (!ls) return { fatal: "no liveSocket" };
  let hk = null;
  for (const v of Object.values(ls.roots || {})) {
    for (const h of Object.values(v.viewHooks || {})) {
      if (h && h.el && h.el.id === "message-list") hk = h;
    }
  }
  if (!hk) return { fatal: "no #message-list hook" };
  window.__hk = hk;
  window.__tr = [];
  window.__t0 = performance.now();
  const rec = (type, extra) => {
    const sc = document.getElementById("chat-message-scroller");
    const e = {
      t: Math.round(performance.now() - window.__t0), type,
      st: sc ? Math.round(sc.scrollTop) : null,
      sh: sc ? sc.scrollHeight : null,
      ch: sc ? sc.clientHeight : null,
      d: sc ? Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight) : null,
      chip: !!document.querySelector(".chat-jump-chip"),
    };
    if (extra) Object.assign(e, extra);
    window.__tr.push(e);
  };
  if (hk.beforeUpdate) {
    const orig = hk.beforeUpdate.bind(hk);
    hk.beforeUpdate = function () { orig(); rec("beforeUpdate", { preD: this._preUpdateDistance }); };
  }
  if (hk.updated) {
    const orig = hk.updated.bind(hk);
    hk.updated = function () { rec("updated:enter"); orig(); rec("updated:exit"); };
  }
  if (hk.scrollToBottom) {
    const orig = hk.scrollToBottom.bind(hk);
    hk.scrollToBottom = function (d) {
      const before = this.scrollEl.scrollTop;
      rec("scrollToBottom:enter", { arg: d === undefined ? null : d });
      orig(d);
      rec("scrollToBottom:exit", { snapRan: this.scrollEl.scrollTop !== before });
    };
  }
  if (typeof hk._onViewportResize === "function") {
    const orig = hk._onViewportResize.bind(hk);
    hk._onViewportResize = function () { rec("viewportResize:enter"); orig(); rec("viewportResize:exit"); };
  }
  if (hk._reportDistance) {
    const orig = hk._reportDistance.bind(hk);
    hk._reportDistance = function (pre) { orig(pre); rec("reportDistance", { arg: pre === undefined ? null : pre, away: this._lastAway }); };
  }
  hk.scrollEl.addEventListener("scroll", () => rec("scroll"), { passive: true });
  return { ok: true, hasViewportResize: typeof hk._onViewportResize === "function" };
})()`;

// Type the draft in CHUNKS with real input events: append a chunk to the
// textarea's value, dispatch a bubbles InputEvent (what the composer's
// autosize hook listens to), record the resulting height. Newlines in the
// appended text are what grow the box toward its cap.
async function typeDraft(pg, chunks) {
  const curve = [];
  await pg.evalp(`(() => {
    const ta = document.querySelector("#compose-form textarea");
    ta.focus(); ta.value = "";
    return Math.round(ta.getBoundingClientRect().height);
  })()`);
  for (const chunk of chunks) {
    await pg.evalp(`(() => {
      const ta = document.querySelector("#compose-form textarea");
      ta.value += ${JSON.stringify(chunk)};
      ta.dispatchEvent(new InputEvent("input", {
        bubbles: true, composed: true,
        inputType: "insertText", data: ${JSON.stringify(chunk)},
      }));
      return true;
    })()`);
    await sleep(60);
    curve.push(await pg.evalp(`Math.round(document.querySelector("#compose-form textarea").getBoundingClientRect().height)`));
  }
  return curve;
}

// Real mouse click at the element's viewport coordinates (CDP input domain,
// not a synthetic .click()).
async function realClick(pg, selector) {
  const rect = await pg.evalp(`(() => {
    const el = document.querySelector(${JSON.stringify(selector)});
    if (!el) return null;
    const r = el.getBoundingClientRect();
    el.scrollIntoView({ block: "nearest" });
    const r2 = el.getBoundingClientRect();
    return { x: Math.round(r2.x + r2.width / 2), y: Math.round(r2.y + r2.height / 2),
             w: Math.round(r2.width), h: Math.round(r2.height) };
  })()`);
  if (!rect) throw new Error(`no toggle for ${selector}`);
  await pg.S("Input.dispatchMouseEvent", { type: "mouseMoved", x: rect.x, y: rect.y });
  await pg.S("Input.dispatchMouseEvent", { type: "mousePressed", x: rect.x, y: rect.y, button: "left", clickCount: 1 });
  await pg.S("Input.dispatchMouseEvent", { type: "mouseReleased", x: rect.x, y: rect.y, button: "left", clickCount: 1 });
  return rect;
}

const judge = (s) => ({
  distanceAtOrUnder150: s.d !== null && s.d <= 150,
  newestVisible: !!(s.lastVisible && s.lastVisible.visible),
  noChip: !s.chip,
});
const verdict = (j) => (j.distanceAtOrUnder150 && j.newestVisible && j.noChip ? "PASS" : "FAIL");

(async () => {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const out = {
    gate: "5",
    validation: "01a05893-b917-7008",
    git: GIT_LABEL,
    viewport: { w: W, h: H },
    app: CHAT_URL,
    cdp: process.env.CDP_HOST || "127.0.0.1:9222",
    started: new Date().toISOString(),
    fatal: null,
  };
  try {
    const reader = await session(W, H, "reader");
    await reader.login();
    await reader.evalp(`location.assign(${JSON.stringify(CHAT_URL)})`);
    await until(reader.evalp, `!!(window.liveSocket && document.getElementById("chat-message-scroller"))`, 30000);
    // Wait out the arrival phase (the initial bottom-scan); _initialScroll
    // flips false when it ends.
    await until(
      reader.evalp,
      `(() => { for (const v of Object.values(window.liveSocket.roots || {})) { for (const h of Object.values(v.viewHooks || {})) { if (h && h.el && h.el.id === "message-list") { window.__gate5Hk = h; return !h._initialScroll; } } } return false; })()`,
      30000, 300, "arrival phase to end",
    );
    out.instrumentation = await reader.evalp(INSTRUMENT);
    if (out.instrumentation.fatal) throw new Error("instrumentation: " + JSON.stringify(out.instrumentation));

    // Setup: reader at the bottom, no chip. Nudge if the park drifted.
    let base = await reader.evalp(snapshot);
    if (base.d === null || base.d > 150) {
      await reader.evalp(`(() => { const sc = document.getElementById("chat-message-scroller"); sc.scrollTop = sc.scrollHeight; return true; })()`);
      await sleep(1000);
      base = await reader.evalp(snapshot);
    }
    out.baseline = base;
    if (base.d > 0) throw new Error(`baseline not parked at bottom: d=${base.d}`);

    // ── (a) composer growth ────────────────────────────────────────────────
    const lines = [
      "Gate 5 draft line 1 — long enough that each line wraps in the pane,",
      "line 2, adding real height rather than a rounding error,",
      "line 3, the autosize cap is 200px per the composer config,",
      "line 4, more prose so the textarea keeps growing,",
      "line 5, the scroller above should squeeze as this grows,",
      "line 6, and the viewport observer must notice the squeeze,",
      "line 7, otherwise a bottom-parked reader strands below the edge,",
      "line 8, which is the defect the #848 observer exists to prevent,",
      "line 9, more lines to be safely past the cap,",
      "line 10, padding,",
      "line 11, padding,",
      "line 12, padding,",
      "line 13, padding,",
      "line 14, padding,",
      "line 15, end of draft.",
    ];
    // One chunk per line keeps the growth curve granular (33px -> cap).
    out.composer = {};
    out.composer.growthCurve = await typeDraft(reader, lines.map((l) => l + "\n"));
    await sleep(500); // the spec's settle window
    out.composer.after = await reader.evalp(snapshot);
    out.composer.stabilityAt1500 = (await sleep(1000), await reader.evalp(snapshot));
    out.composer.judge = judge(out.composer.after);
    out.composer.verdict = verdict(out.composer.judge);
    out.composer.trace = await reader.evalp(`window.__tr`);

    // ── (b) canvases drawer open (draft still in the composer) ─────────────
    out.drawer = {};
    out.drawer.toggleRect = await realClick(reader, `[phx-click="canvas_panel_toggle"]`);
    await sleep(500);
    out.drawer.after = await reader.evalp(snapshot);
    out.drawer.stabilityAt1500 = (await sleep(1000), await reader.evalp(snapshot));
    out.drawer.judge = judge(out.drawer.after);
    out.drawer.verdict = verdict(out.drawer.judge);
    out.drawer.trace = await reader.evalp(`window.__tr`);

    reader.browser.close();
  } catch (e) {
    out.fatal = String(e && e.message ? e.message : e).slice(0, 2000);
  }
  out.finished = new Date().toISOString();
  const file = `${OUT_DIR}/gate5-moon-composer-drawer-${W}x${H}.json`;
  fs.writeFileSync(file, JSON.stringify(out, null, 1));
  console.log("WROTE", file);
  if (out.fatal) console.error("FATAL", out.fatal);
  for (const half of ["composer", "drawer"]) {
    const s = out[half] && out[half].after;
    if (!s) { console.log(`${half}: (no measurement)`); continue; }
    console.log(
      `${out.git} ${half}: d=${s.d} taH=${s.taH} chip=${s.chip} drawerOpen=${s.drawerOpen} ` +
        `lastVisible=${s.lastVisible ? s.lastVisible.visible : "?"} rows=${s.rows} ` +
        `sh=${s.sh} ch=${s.ch} st=${s.st} → ${out[half].verdict}`,
    );
  }
  process.exit(0);
})().catch((e) => { console.error("FATAL", e); process.exit(1); });
