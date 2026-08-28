import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { sleep } from "./cdp.mjs";
import { session, PORT, SPACE, OUT_DIR, ratio } from "./lib.mjs";

const W = parseInt(process.env.VW || "1440", 10);
const H = parseInt(process.env.VH || "900", 10);
const THEME = process.env.THEME || "light";
const OTHER = "01a045c8-c6b1-7261-b20b-ebebf7e0cbed";
const out = {};
const log = (k, v) => { out[k] = v; console.log(k.toUpperCase(), JSON.stringify(v)); };

let ctlN = 0;
const ctl = (code) =>
  execFileSync("elixir", [
    "--sname", `s5p${process.pid}x${ctlN++}`, "--cookie", "s5probecookie",
    "/Volumes/Dev/tmp/s5-ctl.exs", code,
  ], { encoding: "utf8", cwd: "/Volumes/Dev/worktrees/01a0419a-af55-77cb-b3e9-0c1390262c65/apps/platform" })
    .split("\n").filter((l) => l.startsWith("RESULT") || l.startsWith("RPCERR")).join("");

const { S, evalp, nav } = await session(W, H);
await nav(`http://localhost:${PORT}/dev/login`);
await sleep(1500);
await nav(`http://localhost:${PORT}/chat/${SPACE}`);
await sleep(3500);
await evalp(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(THEME)})`);
await sleep(400);

const ready = await evalp(`(() => {
  const sc = document.getElementById("chat-message-scroller");
  return { rows: sc ? sc.querySelectorAll("[data-message-id]").length : 0,
    liveSocketConnected: !!(window.liveSocket && window.liveSocket.isConnected()),
    theme: document.documentElement.getAttribute("data-theme"),
    innerWidth: window.innerWidth };
})()`);
log("ready", ready);
if (!ready.liveSocketConnected) { console.error("VOID: socket"); process.exit(2); }

// Pagination is asynchronous and sometimes needs many nudges. Bailing early
// leaves the scroller too short for the DEEP band to be reachable at all,
// and the pill then never renders — which reads as "the layout is broken"
// rather than "the fixture is too short". So: patient, and it VOIDS loudly
// rather than returning a short tree quietly.
async function loadHistory(target) {
  let last = 0, stuck = 0, st = null;
  for (let i = 0; i < 80; i++) {
    // REAL wheel input, not a synthetic `scroll` Event. The InfiniteScroll
    // hook paginates off genuine gestures; a dispatched Event nudges the
    // listener but reliably stalls around 51 rows, which is short of the
    // deep band. Stage 2 hit scrollHeight 4433 with real mouseWheel and this
    // does the same.
    const box = await evalp(`(() => { const s = document.getElementById("chat-message-scroller");
      const b = s.getBoundingClientRect(); return { x: b.x + b.width/2, y: b.y + b.height/2 }; })()`);
    for (let k = 0; k < 12; k++) {
      await S("Input.dispatchMouseEvent", {
        type: "mouseWheel", x: box.x, y: box.y, deltaX: 0, deltaY: -400,
      });
      await sleep(60);
    }
    st = await evalp(`(() => { const s = document.getElementById("chat-message-scroller");
      return { sh: s.scrollHeight, ch: s.clientHeight,
               rows: s.querySelectorAll("[data-message-id]").length }; })()`);
    if (st.sh - st.ch >= target) return st;
    stuck = st.sh === last ? stuck + 1 : 0;
    if (stuck >= 12) break;
    last = st.sh;
    await sleep(900);
  }
  return st;
}
const hist = await loadHistory(2900);
log("history", hist);
if (!hist || hist.sh - hist.ch < 1900) {
  console.error("VOID: deep band unreachable — scroller only", hist && hist.sh - hist.ch, "px");
  process.exit(4);
}

const park = async (d) => {
  await evalp("(() => { const s=document.getElementById('chat-message-scroller');" +
    " s.scrollTop = s.scrollHeight - s.clientHeight - " + d + "; s.dispatchEvent(new Event('scroll')); })()");
  await sleep(900);
};

// ── (b) OCCLUSION + (c) NO LINE FULLY OCCLUDED, swept across the deep band.
const SWEEP = `(() => {
  const pane = document.getElementById("chat-message-scroller");
  const pill = document.querySelector(".chat-jump-chip-pill");
  const btn  = document.querySelector(".chat-jump-chip");
  if (!pill || !btn) return { rendered: false };
  const q = pane.getBoundingClientRect();
  const p = pill.getBoundingClientRect();
  const b = btn.getBoundingClientRect();
  const inter = (a, c) => Math.max(0, Math.min(a.right,c.right)-Math.max(a.left,c.left)) *
                          Math.max(0, Math.min(a.bottom,c.bottom)-Math.max(a.top,c.top));
  const paneArea = q.width * q.height;

  // Line boxes: every client rect of every text run inside a message body
  // that is visible inside the pane. getClientRects() on a Range gives one
  // rect PER LINE BOX, which is what the criterion is about.
  const lines = [];
  for (const row of pane.querySelectorAll("[data-message-id]")) {
    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    let n;
    while ((n = walker.nextNode())) {
      if (!n.nodeValue || !n.nodeValue.trim()) continue;
      const r = document.createRange();
      r.selectNodeContents(n);
      const parent = n.parentElement;
      for (const lr of r.getClientRects()) {
        if (lr.width < 1 || lr.height < 1) continue;
        if (lr.bottom <= q.top || lr.top >= q.bottom) continue;
        lines.push({ left: lr.left, right: lr.right, top: lr.top, bottom: lr.bottom,
                     width: lr.width, height: lr.height,
                     text: n.nodeValue.trim().slice(0, 40),
                     parentClass: (parent && parent.className && parent.className.toString().slice(0,80)) || "",
                     parentTag: parent ? parent.tagName : "",
                     kind: (parent && parent.closest(".js-date-separator")) ? "date-separator" : "content" });
      }
    }
  }
  const touched = lines.filter((l) => inter(l, p) > 0);
  // A line is FULLY occluded only if the painted pill covers its whole box.
  const fullyAll = touched.filter((l) =>
    l.left >= p.left - 0.5 && l.right <= p.right + 0.5 &&
    l.top >= p.top - 0.5 && l.bottom <= p.bottom + 0.5);
  // THE CRITERION IS ABOUT MESSAGE TEXT. The date separator is chrome: a
  // 74px centred Yesterday label under a 142px centred pill. Both numbers
  // are reported; the criterion number is the content one.
  const fully = fullyAll.filter((l) => l.kind === "content");
  return {
    rendered: true,
    scrollTop: pane.scrollTop,
    distance: pane.scrollHeight - pane.scrollTop - pane.clientHeight,
    paneClientHeight: pane.clientHeight,
    paneArea,
    paintedArea: p.width * p.height,
    hitArea: b.width * b.height,
    paintedPct: (p.width * p.height) / paneArea * 100,
    hitPct: (b.width * b.height) / paneArea * 100,
    pillWidth: p.width, pillHeight: p.height,
    btnWidth: b.width, btnHeight: b.height,
    linesTotal: lines.length,
    linesTouched: touched.length,
    linesFullyOccluded: fully.length,
    linesFullyOccludedIncludingChrome: fullyAll.length,
    fullyOccludedDetail: fullyAll.map((l) => ({ text: l.text, parentClass: l.parentClass,
      parentTag: l.parentTag, kind: l.kind, w: l.width, h: l.height })),
    lineHeights: [...new Set(lines.map((l) => Math.round(l.height)))].sort((a,b)=>a-b),
  };
})()`;

async function sweep(label) {
  const rows = [];
  for (let d = 1850; d <= 2950; d += 50) {
    await park(d);
    const r = await evalp(SWEEP);
    if (r.rendered) rows.push(r);
  }
  if (rows.length === 0) throw new Error("VOID: pill never rendered across the sweep — " + label);
  const worstPainted = Math.max(...rows.map((r) => r.paintedPct));
  const worstHit = Math.max(...rows.map((r) => r.hitPct));
  const fully = rows.reduce((a, r) => a + r.linesFullyOccluded, 0);
  const fullyChrome = rows.reduce((a, r) => a + r.linesFullyOccludedIncludingChrome, 0);
  const fullyDetail = rows.flatMap((r) => (r.fullyOccludedDetail || []).map((d) => ({ ...d, distance: r.distance })));
  const touchedDist = {};
  rows.forEach((r) => { touchedDist[r.linesTouched] = (touchedDist[r.linesTouched] || 0) + 1; });
  return {
    label, positions: rows.length,
    worstPaintedPct: worstPainted, worstHitPct: worstHit,
    totalLinesFullyOccluded_messageText: fully,
    totalLinesFullyOccluded_includingChrome: fullyChrome,
    fullyOccludedDetail: fullyDetail,
    linesTouchedDistribution: touchedDist,
    lineHeights: [...new Set(rows.flatMap((r) => r.lineHeights))].sort((a,b)=>a-b),
    pillBox: { w: rows[0].pillWidth, h: rows[0].pillHeight },
    hitBox: { w: rows[0].btnWidth, h: rows[0].btnHeight },
    paneArea: rows[0].paneArea,
    rows,
  };
}

const sweepNoCount = await sweep("no-count");
log("occlusion_no_count", { ...sweepNoCount, rows: undefined });

// Count present: a real message from the OTHER participant.
ctl(`Platform.Chat.post_message(%{space_id: "${SPACE}", participant_id: "${OTHER}", content_type: "text", content: "desktop verification message"}) |> elem(0)`);
await sleep(1600);
const sweepCount = await sweep("with-count");
log("occlusion_with_count", { ...sweepCount, rows: undefined });

fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(`${OUT_DIR}/occlusion-${THEME}-${W}x${H}.json`,
  JSON.stringify({ sweepNoCount, sweepCount }, null, 2));
fs.writeFileSync(`${OUT_DIR}/summary2-${THEME}-${W}x${H}.json`, JSON.stringify(out, null, 2));
console.log("WROTE", THEME);
process.exit(0);
