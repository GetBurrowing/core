import fs from "node:fs";
import { sleep } from "./cdp.mjs";
import { session, PORT, SPACE, OUT_DIR } from "./lib.mjs";

const W = parseInt(process.env.VW || "1440", 10);
const H = parseInt(process.env.VH || "900", 10);
const THEME = process.env.THEME || "light";
const out = {};
const log = (k, v) => {
  out[k] = v;
  console.log(k.toUpperCase(), JSON.stringify(v));
};

const { S, evalp, nav } = await session(W, H);

await nav(`http://localhost:${PORT}/dev/login`);
await sleep(1500);
await evalp(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(THEME)})`);
await nav(`http://localhost:${PORT}/chat/${SPACE}`);
await sleep(3500);
await evalp(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(THEME)})`);
await sleep(400);

// ── FIXTURE READBACK, after boot. A screenshot of a dead LiveView proves
//    nothing, and unbuilt assets make it prove nothing either.
const ready = await evalp(`(() => {
  const sc = document.getElementById("chat-message-scroller");
  const probe = document.createElement("div");
  probe.className = "chat-jump-anchor-row";
  document.body.appendChild(probe);
  const cssLoaded = getComputedStyle(probe).position === "absolute";
  probe.remove();
  return {
    url: location.href,
    scroller: !!sc,
    rows: sc ? sc.querySelectorAll("[data-message-id]").length : 0,
    scrollHeight: sc ? sc.scrollHeight : null,
    clientHeight: sc ? sc.clientHeight : null,
    liveSocketConnected: !!(window.liveSocket && window.liveSocket.isConnected()),
    theme: document.documentElement.getAttribute("data-theme"),
    stylesheetApplied: cssLoaded,
    innerWidth: window.innerWidth,
  };
})()`);
log("ready", ready);
if (!ready.scroller || !ready.liveSocketConnected || !ready.stylesheetApplied) {
  fs.writeFileSync(`${OUT_DIR}/ERROR-${THEME}-${W}x${H}.json`, JSON.stringify({ ready }, null, 2));
  console.error("VOID: fixture/socket/stylesheet precondition failed");
  process.exit(2);
}

// ── Load enough history that the DEEP band is reachable at all.
//    Only ~50 rows land on first paint; at 730px of pane that is a max
//    distance of ~1485px, BELOW DEEP_HISTORY_PX (1800). Without this the
//    deep band is unreachable and the pill never renders — which would read
//    as "the layout did not apply" rather than "the fixture was too short".
async function loadHistory(target) {
  let last = 0;
  for (let i = 0; i < 40; i++) {
    const st = await evalp(`(() => {
      const s = document.getElementById("chat-message-scroller");
      s.scrollTop = 0;
      s.dispatchEvent(new Event("scroll"));
      return { sh: s.scrollHeight, ch: s.clientHeight, rows: s.querySelectorAll("[data-message-id]").length };
    })()`);
    if (st.sh - st.ch >= target) return st;
    if (st.sh === last && i > 6) return st;
    last = st.sh;
    await sleep(700);
  }
  return await evalp(`(() => { const s = document.getElementById("chat-message-scroller");
    return { sh: s.scrollHeight, ch: s.clientHeight, rows: s.querySelectorAll("[data-message-id]").length }; })()`);
}
const loaded = await loadHistory(2600);
log("history_loaded", loaded);

// Park at a distance inside the DEEP band so the pill renders with no count.
const showPill = async (distance = 2200) => {
  await evalp(
    "(() => { const s = document.getElementById('chat-message-scroller');" +
      " s.scrollTop = s.scrollHeight - s.clientHeight - " + distance + ";" +
      " s.dispatchEvent(new Event('scroll')); })()",
  );
  await sleep(1400);
};
await showPill();

// ── BREAKPOINT GATE. Assert the promoted layout actually applied rather
//    than assuming a width query worked.
//
//    THE SPEC'S CHECK IS WRONG AND IS NOT USED. It says assert
//    `.chat-jump-anchor` computes `position: absolute`. It does not, and it
//    never did in either layout: the OLD desktop rule was
//    `.chat-jump-anchor, .chat-jump-anchor-row { display: contents }` (so
//    `position: static`), and the NEW promoted rule is
//    `.chat-jump-anchor { display: block; position: relative }`. `absolute`
//    belongs to `.chat-jump-anchor-row`. Asserting it on the anchor would
//    void every run including a correct one, so the discriminator below
//    checks BOTH elements against the values that actually distinguish the
//    two layouts, and additionally refutes `display: contents` by name.
const gate = await evalp(`(() => {
  const a = document.querySelector(".chat-jump-anchor");
  const r = document.querySelector(".chat-jump-anchor-row");
  if (!a || !r) return { present: false };
  const ca = getComputedStyle(a), cr = getComputedStyle(r);
  return {
    present: true,
    innerWidth: window.innerWidth,
    anchor: { display: ca.display, position: ca.position, height: ca.height },
    row: { display: cr.display, position: cr.position, pointerEvents: cr.pointerEvents },
  };
})()`);
log("breakpoint_gate", gate);
const gateOk =
  gate.present &&
  gate.innerWidth === W &&
  gate.anchor.display === "block" &&
  gate.anchor.position === "relative" &&
  gate.row.display === "flex" &&
  gate.row.position === "absolute" &&
  gate.row.pointerEvents === "none";
log("breakpoint_gate_ok", gateOk);
if (!gateOk) {
  fs.writeFileSync(`${OUT_DIR}/ERROR-gate-${THEME}-${W}x${H}.json`, JSON.stringify(out, null, 2));
  console.error("VOID: the promoted desktop layout did not apply");
  process.exit(3);
}

// ── (a) PANE CENTRING, sidebar expanded then collapsed.
const centringAt = async (label) => {
  const r = await evalp(`(() => {
    const pill = document.querySelector(".chat-jump-chip-pill");
    const btn  = document.querySelector(".chat-jump-chip");
    const pane = document.getElementById("chat-message-scroller");
    if (!pill || !pane) return null;
    const p = pill.getBoundingClientRect();
    const q = pane.getBoundingClientRect();
    const b = btn.getBoundingClientRect();
    return {
      pillCentreX: p.x + p.width / 2,
      paneCentreX: q.x + q.width / 2,
      viewportCentreX: window.innerWidth / 2,
      offsetFromPane: (p.x + p.width / 2) - (q.x + q.width / 2),
      offsetFromViewport: (p.x + p.width / 2) - (window.innerWidth / 2),
      paneRect: { x: q.x, width: q.width, height: q.height },
      pillRect: { x: p.x, y: p.y, width: p.width, height: p.height },
      buttonRect: { x: b.x, y: b.y, width: b.width, height: b.height },
    };
  })()`);
  return { label, ...r };
};

const centringExpanded = await centringAt("sidebar-expanded");
log("centring_expanded", centringExpanded);

// Collapse the sidebar through the real control, so the real event fires.
const toggled = await evalp(`(() => {
  const b = document.querySelector('button[phx-click="toggle_sidebar"]');
  if (!b) return { found: false };
  b.click();
  return { found: true };
})()`);
log("sidebar_toggle", toggled);
await sleep(1600);
await showPill();
const centringCollapsed = await centringAt("sidebar-collapsed");
log("centring_collapsed", centringCollapsed);

// Restore the sidebar.
await evalp(`(() => { const b = document.querySelector('button[phx-click="toggle_sidebar"]'); if (b) b.click(); })()`);
await sleep(1600);
await showPill();

// ── (e) HOVER / FOCUS-VISIBLE DO NOT MOVE THE BOX.
//    Forced via CSS.forcePseudoState, NOT Emulation.setEmulatedMedia.
const rects = async (tag) => {
  const r = await evalp(`(() => {
    const pill = document.querySelector(".chat-jump-chip-pill");
    const btn  = document.querySelector(".chat-jump-chip");
    const f = (e) => { const b = e.getBoundingClientRect();
      return { x: b.x, y: b.y, w: b.width, h: b.height, top: b.top, left: b.left, right: b.right, bottom: b.bottom }; };
    return { pill: f(pill), button: f(btn) };
  })()`);
  return { tag, ...r };
};
const doc = await S("DOM.getDocument", { depth: -1 });
const { nodeId: chipNode } = await S("DOM.querySelector", {
  nodeId: doc.root.nodeId,
  selector: ".chat-jump-chip",
});
if (!chipNode) throw new Error("VOID: no .chat-jump-chip node for forcePseudoState");
const rest = await rects("rest");
await S("CSS.forcePseudoState", { nodeId: chipNode, forcedPseudoClasses: ["hover"] });
await sleep(400);
const hovered = await rects("hover");
await S("CSS.forcePseudoState", { nodeId: chipNode, forcedPseudoClasses: ["focus-visible"] });
await sleep(400);
const focused = await rects("focus-visible");
await S("CSS.forcePseudoState", { nodeId: chipNode, forcedPseudoClasses: [] });
await sleep(300);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
log("hover_box", {
  rest, hovered, focused,
  hover_identical: same(rest.pill, hovered.pill) && same(rest.button, hovered.button),
  focus_identical: same(rest.pill, focused.pill) && same(rest.button, focused.button),
});

// ── (g) ZERO LAYOUT SHIFT: composer top edge with and without the pill.
// The composer is `.compose-input-area` (composer.ex:419), the flex-shrink-0
// wrapper that the jump anchor sits directly above in the column. Pinned by
// that class rather than by a fallback chain: an earlier version of this
// probe fell through to `hidden md:block`, an unrelated element 700px up the
// page which of course never moves — a delta of 0 that measured nothing.
// The assertion below refuses to report a number unless it found that class
// AND the textarea inside it.
const composerTop = () => evalp(`(() => {
  const c = document.querySelector(".compose-input-area");
  if (!c) return { found: false };
  const b = c.getBoundingClientRect();
  const ta = c.querySelector("textarea, input[type=text]");
  const form = c.querySelector("#compose-form");
  return {
    found: true,
    top: b.top, bottom: b.bottom, height: b.height,
    formTop: form ? form.getBoundingClientRect().top : null,
    textareaTop: ta ? ta.getBoundingClientRect().top : null,
    className: c.className,
  };
})()`);
const withPill = await composerTop();
await evalp(`(() => { const s = document.getElementById("chat-message-scroller"); s.scrollTop = s.scrollHeight; s.dispatchEvent(new Event("scroll")); })()`);
await sleep(1500);
const noPill = await composerTop();
const gone = await evalp(`(() => ({
  chip: document.querySelectorAll(".chat-jump-chip").length,
  pill: document.querySelectorAll(".chat-jump-chip-pill").length,
  row: document.querySelectorAll(".chat-jump-anchor-row").length,
}))()`);
if (!withPill.found || !noPill.found) throw new Error("VOID: .compose-input-area not found");
log("layout_shift", {
  withPill, noPill,
  delta_top: withPill.top - noPill.top,
  delta_formTop: withPill.formTop - noPill.formTop,
  delta_textareaTop: withPill.textareaTop - noPill.textareaTop,
  atBottomCounts: gone,
});

fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(`${OUT_DIR}/desktop-${THEME}-${W}x${H}.json`, JSON.stringify(out, null, 2));
console.log("WROTE", `${OUT_DIR}/desktop-${THEME}-${W}x${H}.json`);
process.exit(0);
