import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { sleep } from "./cdp.mjs";
import { session, PORT, SPACE, OUT_DIR, grabPixels, ratio, lum } from "./lib.mjs";

const W = 1440, H = 900;
const THEME = process.env.THEME || "light";
const OTHER = "01a045c8-c6b1-7261-b20b-ebebf7e0cbed";
const out = {};
const log = (k, v) => { out[k] = v; console.log(k.toUpperCase(), JSON.stringify(v)); };
let n = 0;
const ctl = (code) => {
  fs.writeFileSync("/Volumes/Dev/tmp/s5-inline.exs", code);
  return execFileSync("elixir", ["--sname", `s5d${process.pid}n${n++}`, "--cookie", "s5probecookie",
    "/Volumes/Dev/tmp/s5-ctl2.exs", "/Volumes/Dev/tmp/s5-inline.exs"],
    { encoding: "utf8", cwd: "/Volumes/Dev/worktrees/01a0419a-af55-77cb-b3e9-0c1390262c65/apps/platform" })
    .split("\n").filter(l => l.startsWith("RAW")).join("").slice(0, 200);
};

const { S, evalp, nav } = await session(W, H);
await nav(`http://localhost:${PORT}/dev/login`);
await sleep(1500);
await nav(`http://localhost:${PORT}/chat/${SPACE}`);
await sleep(3500);
await evalp(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(THEME)})`);
await sleep(400);
log("ready", await evalp(`({ live: !!(window.liveSocket && window.liveSocket.isConnected()),
  theme: document.documentElement.getAttribute("data-theme"), w: window.innerWidth })`));

async function loadHistory(target) {
  let last = 0, stuck = 0, st = null;
  for (let i = 0; i < 80; i++) {
    const box = await evalp(`(() => { const s = document.getElementById("chat-message-scroller");
      const b = s.getBoundingClientRect(); return { x: b.x + b.width/2, y: b.y + b.height/2 }; })()`);
    for (let k = 0; k < 12; k++) {
      await S("Input.dispatchMouseEvent", { type: "mouseWheel", x: box.x, y: box.y, deltaX: 0, deltaY: -400 });
      await sleep(60);
    }
    st = await evalp(`(() => { const s = document.getElementById("chat-message-scroller");
      return { sh: s.scrollHeight, ch: s.clientHeight, rows: s.querySelectorAll("[data-message-id]").length }; })()`);
    if (st.sh - st.ch >= target) return st;
    stuck = st.sh === last ? stuck + 1 : 0;
    if (stuck >= 12) break;
    last = st.sh; await sleep(900);
  }
  return st;
}
const hist = await loadHistory(2900);
log("history", hist);
if (!hist || hist.sh - hist.ch < 1900) { console.error("VOID: deep band unreachable"); process.exit(4); }

const park = async (d) => {
  await evalp("(() => { const s=document.getElementById('chat-message-scroller');" +
    " s.scrollTop = s.scrollHeight - s.clientHeight - " + d + "; s.dispatchEvent(new Event('scroll')); })()");
  await sleep(1000);
};
await park(2200);

// ── (d) TARGETS ENUMERATED FROM THE RENDERED DOM.
//    Desktop chrome is NOT the mobile bottom-nav; nothing here assumes five
//    tabs. Everything interactive whose centre lands in the bottom-right
//    quadrant of the viewport, plus the composer input and send control by
//    name, deduplicated.
const ENUM = `(() => {
  const sel = "button, a[href], input, textarea, [role=button], [phx-click]";
  const vis = (el) => {
    if (!el.getClientRects().length) return false;
    const c = getComputedStyle(el);
    if (c.visibility === "hidden" || c.display === "none") return false;
    if (parseFloat(c.opacity) < 0.01) return false;
    // An ancestor may be the thing that is transparent (the per-message hover
    // toolbars are opacity-0 until the row is hovered).
    for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
      const ca = getComputedStyle(a);
      if (ca.visibility === "hidden" || ca.display === "none") return false;
      if (parseFloat(ca.opacity) < 0.01) return false;
    }
    return true;
  };
  const seen = new Map();
  const excluded = { invisible: 0, offViewport: 0, tiny: 0, isThePill: 0 };
  for (const el of document.querySelectorAll(sel)) {
    const b = el.getBoundingClientRect();
    if (b.width < 4 || b.height < 4) { excluded.tiny++; continue; }
    const cx = b.x + b.width / 2, cy = b.y + b.height / 2;
    if (cx < window.innerWidth / 2 || cy < window.innerHeight / 2) continue;
    if (el.closest(".chat-jump-chip")) { excluded.isThePill++; continue; }
    // Must be ON SCREEN — elementFromPoint returns null outside the viewport,
    // and a null hit is "not on screen", NOT "blocked by the pill". Counting
    // those as unreachable is how this probe first read 314 failures.
    if (cx < 0 || cy < 0 || cx >= window.innerWidth || cy >= window.innerHeight) {
      excluded.offViewport++; continue;
    }
    if (!vis(el)) { excluded.invisible++; continue; }
    const key = Math.round(cx) + "," + Math.round(cy);
    if (!seen.has(key)) seen.set(key, {
      tag: el.tagName, cls: (el.className || "").toString().slice(0, 60),
      label: (el.getAttribute("aria-label") || el.textContent || "").trim().slice(0, 30),
      inScroller: !!el.closest("#chat-message-scroller"),
      cx, cy,
    });
  }
  const extra = [];
  const ta = document.querySelector(".compose-input-area textarea, .compose-input-area input[type=text]");
  const send = document.querySelector(".compose-pill-send") ||
               document.querySelector(".compose-input-area button[type=submit]");
  for (const [name, el] of [["composer-input", ta], ["send-control", send]]) {
    if (!el) { extra.push({ name, missing: true }); continue; }
    const b = el.getBoundingClientRect();
    extra.push({ name, tag: el.tagName, cls: (el.className||"").toString().slice(0,60),
                 cx: b.x + b.width/2, cy: b.y + b.height/2 });
  }
  return { quadrant: [...seen.values()], named: extra, excluded };
})()`;

const HITTEST = (targets) => `(() => {
  const pane = document.getElementById("chat-message-scroller");
  const ts = ${JSON.stringify(targets)};
  const res = ts.map(t => {
    const hit = document.elementFromPoint(t.cx, t.cy);
    const inPill = hit ? !!hit.closest(".chat-jump-chip, .chat-jump-anchor-row") : false;
    return {
      ...t,
      hitTag: hit ? hit.tagName : null,
      hitCls: hit ? (hit.className || "").toString().slice(0, 60) : null,
      offViewport: !hit,
      blockedByPill: inPill,
      // The only failure this criterion is about: the pill (or its
      // full-width centring row) intercepting a point that belongs to
      // another control. A null hit is recorded separately, not folded in.
      reachable: !!hit && !inPill,
    };
  });
  return {
    paneClientHeight: pane.clientHeight,
    pillPresent: !!document.querySelector(".chat-jump-chip"),
    countPresent: !!document.querySelector(".chat-jump-chip-count"),
    typingAnywhere: document.querySelectorAll(".animate-bounce").length,
    results: res,
  };
})()`;

const enumerated = await evalp(ENUM);
const targets = [
  ...enumerated.quadrant,
  ...enumerated.named.filter(e => !e.missing).map(e => ({ ...e })),
];
log("targets_enumerated", { count: targets.length, targets });

const geometry = async (label) => {
  const r = await evalp(HITTEST(targets));
  return { label, ...r, unreachable: r.results.filter(x => x.blockedByPill) };
};

const A = await geometry("A: no count");
ctl(`Platform.Chat.post_message(%{space_id: "${SPACE}", participant_id: "${OTHER}", content_type: "text", content: "reachability geometry B"})`);
await sleep(1800);
await park(2200);
const B = await geometry("B: count present");
ctl(`Platform.Chat.PubSub.broadcast("${SPACE}", {:agent_typing, %{space_id: "${SPACE}", participant_id: "${OTHER}", typing: true}})`);
await sleep(1600);
const C = await geometry("C: typing indicator raised");
ctl(`Platform.Chat.PubSub.broadcast("${SPACE}", {:agent_typing, %{space_id: "${SPACE}", participant_id: "${OTHER}", typing: false}})`);
await sleep(800);

const heights = [A, B, C].map(g => g.paneClientHeight);
log("reachability", {
  geometries: [A, B, C].map(g => ({
    label: g.label, paneClientHeight: g.paneClientHeight,
    pillPresent: g.pillPresent, countPresent: g.countPresent,
    typingBounceNodes: g.typingAnywhere,
    targets: g.results.length,
    blockedByPill: g.results.filter(x => x.blockedByPill).map(u => u.label || u.name || u.cls),
    offViewport: g.results.filter(x => x.offViewport).length,
  })),
  paneClientHeights: heights,
  GEOMETRY_C_IS_REAL: heights[2] !== heights[0],
  totalHitTests: A.results.length + B.results.length + C.results.length,
  totalBlockedByPill: A.unreachable.length + B.unreachable.length + C.unreachable.length,
  excluded: enumerated.excluded,
});

fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(`${OUT_DIR}/reach-${THEME}.json`, JSON.stringify({ A, B, C, enumerated }, null, 2));
fs.writeFileSync(`${OUT_DIR}/summary3-${THEME}.json`, JSON.stringify(out, null, 2));
console.log("WROTE3", THEME);
process.exit(0);
