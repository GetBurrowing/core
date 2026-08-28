import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { sleep } from "./cdp.mjs";
import { session, PORT, SPACE, OUT_DIR, grabPixels, ratio, lum } from "./lib.mjs";

const W = 1440, H = 900;
const THEME = process.env.THEME || "light";
const out = {};
const log = (k, v) => { out[k] = v; console.log(k.toUpperCase(), JSON.stringify(v)); };

// A message ~55 back from the live edge: old enough that centring it leaves
// the reader inside the DEEP band, recent enough to still be paginated in.
const rawId = execFileSync("elixir", ["--sname", `s5f${process.pid}`, "--cookie", "s5probecookie",
  "/Volumes/Dev/tmp/s5-ctl2.exs", "/Volumes/Dev/tmp/s5-pickmsg.exs"],
  { encoding: "utf8", cwd: "/Volumes/Dev/worktrees/01a0419a-af55-77cb-b3e9-0c1390262c65/apps/platform" });
const MSG = (rawId.match(/RAW \{"([0-9a-f-]{36})"/) || [])[1];
log("highlight_target_message", MSG);
if (!MSG) { console.error("VOID: could not pick a message id"); process.exit(2); }

const { S, evalp, nav } = await session(W, H);
await nav(`http://localhost:${PORT}/dev/login`);
await sleep(1500);
await nav(`http://localhost:${PORT}/chat/${SPACE}?message=${MSG}`);
await sleep(4000);
await evalp(`document.documentElement.setAttribute("data-theme", ${JSON.stringify(THEME)})`);
await sleep(600);

// ── Confirm the HIGHLIGHTED fixture actually built. `bg-primary/5 ring-1
//    ring-primary/20` (chat_message.ex:54) is the real worst ground: there is
//    no saturated cyan own-message bubble in this product.
const hl = await evalp(`(() => {
  const row = document.querySelector('[data-message-id="${MSG}"]');
  if (!row) return { found: false };
  const cs = getComputedStyle(row);
  return { found: true, cls: row.className,
    isHighlighted: /bg-primary\\/5/.test(row.className),
    background: cs.backgroundColor, boxShadow: cs.boxShadow.slice(0, 60) };
})()`);
log("highlight_fixture", hl);
if (!hl.found || !hl.isHighlighted) { console.error("VOID: highlighted fixture did not build"); process.exit(3); }

// Bring the highlighted row under the pill while staying in the DEEP band.
let align = null;
for (let i = 0; i < 24; i++) {
  align = await evalp(`(() => {
    const s = document.getElementById("chat-message-scroller");
    const row = document.querySelector('[data-message-id="${MSG}"]');
    const pill = document.querySelector(".chat-jump-chip-pill");
    if (!row) return { ok: false, why: "row gone" };
    if (!pill) return { ok: false, why: "pill absent",
      distance: s.scrollHeight - s.scrollTop - s.clientHeight };
    const r = row.getBoundingClientRect(), p = pill.getBoundingClientRect();
    const overlap = Math.max(0, Math.min(r.bottom, p.bottom) - Math.max(r.top, p.top));
    return { ok: overlap >= p.height * 0.9, overlap,
      delta: (r.top + r.height / 2) - (p.top + p.height / 2),
      distance: s.scrollHeight - s.scrollTop - s.clientHeight,
      rowTop: r.top, rowBottom: r.bottom, pillTop: p.top, pillBottom: p.bottom };
  })()`);
  if (align.ok) break;
  const step = align.delta !== undefined ? align.delta : 200;
  await evalp("(() => { const s=document.getElementById('chat-message-scroller');" +
    " s.scrollTop = s.scrollTop + (" + step + "); s.dispatchEvent(new Event('scroll')); })()");
  await sleep(450);
}
log("alignment", align);
if (!align.ok) { console.error("VOID: could not place the highlighted row under the pill"); process.exit(4); }
if (align.distance <= 1800) { console.error("VOID: alignment left the deep band, pill not in its own state"); process.exit(5); }

// ── PIXEL SAMPLE. Token arithmetic errs toward passing because it cannot
//    model the backdrop-blur scrim; these are screenshot pixels.
const boxes = await evalp(`(() => {
  const pill = document.querySelector(".chat-jump-chip-pill");
  const label = pill.querySelector(".truncate") || pill;
  const p = pill.getBoundingClientRect(), l = label.getBoundingClientRect();
  return {
    pill: { x: Math.round(p.x), y: Math.round(p.y), w: Math.round(p.width), h: Math.round(p.height) },
    label: { x: Math.round(l.x), y: Math.round(l.y), w: Math.round(l.width), h: Math.round(l.height) },
    labelText: label.textContent.trim().slice(0, 30),
    labelColor: getComputedStyle(label).color,
  };
})()`);
log("boxes", boxes);

const px = await grabPixels(S, evalp, boxes.pill);
const pillPixels = [];
for (let i = 0; i < px.data.length; i += 4) pillPixels.push([px.data[i], px.data[i+1], px.data[i+2]]);

const lpx = await grabPixels(S, evalp, boxes.label);
const labelPixels = [];
for (let i = 0; i < lpx.data.length; i += 4) labelPixels.push([lpx.data[i], lpx.data[i+1], lpx.data[i+2]]);

// Background = the most common colour inside the painted pill (the composite
// AFTER the blur has run). Text = the extreme-luminance pixel inside the
// label box, in whichever direction the theme puts it.
const freq = new Map();
for (const p of pillPixels) { const k = p.join(","); freq.set(k, (freq.get(k) || 0) + 1); }
const bg = [...freq.entries()].sort((a, b) => b[1] - a[1])[0][0].split(",").map(Number);
const bgLum = lum(bg);
const sorted = [...labelPixels].sort((a, b) => lum(a) - lum(b));
const darkTheme = bgLum <= 0.5;
// GLYPH CORE — the fully-covered pixel. This is the text colour as WCAG
// means it, and it is what a token-arithmetic computation is trying to
// predict. Optimistic in the sense that it is the best pixel in the label.
const textCore = darkTheme ? sorted[sorted.length - 1] : sorted[0];
// CONSERVATIVE — the 10th percentile from the text end, so antialiased edge
// pixels and any blur bleed are included. Deliberately understates contrast.
// If this clears 4.5 the criterion is met with no argument about sampling.
const idx = Math.floor(sorted.length * 0.10);
const textConservative = darkTheme ? sorted[sorted.length - 1 - idx] : sorted[idx];
const text = textCore;

log("contrast", {
  theme: THEME,
  surface_named: "the painted pill composited over a HIGHLIGHTED message row (bg-primary/5 + ring-primary/20, chat_message.ex:54) — the real worst ground; there is no saturated cyan own-message bubble in this product",
  label_text: boxes.labelText,
  declared_label_color: boxes.labelColor,
  sampled_background_rgb: bg,
  sampled_text_rgb: text,
  background_luminance: bgLum,
  sampled_text_rgb_conservative_p10: textConservative,
  contrast_ratio_glyph_core: ratio(textCore, bg),
  contrast_ratio_conservative_p10: ratio(textConservative, bg),
  requirement: 4.5,
  passes_glyph_core: ratio(textCore, bg) >= 4.5,
  passes_conservative: ratio(textConservative, bg) >= 4.5,
  method: "screenshot pixels. background = modal RGB inside the painted pill (the composite AFTER backdrop-blur). text = extreme-luminance pixel in the label box (glyph core), plus a 10th-percentile variant that includes antialiased edges.",
  pill_pixels_sampled: pillPixels.length,
  label_pixels_sampled: labelPixels.length,
});

fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(`${OUT_DIR}/contrast-${THEME}.json`, JSON.stringify(out, null, 2));
console.log("WROTE4", THEME);
process.exit(0);
