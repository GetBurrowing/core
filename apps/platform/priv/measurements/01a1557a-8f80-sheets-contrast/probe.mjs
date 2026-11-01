// Agents and Members sheets: the non-text pairs daisyUI paints through an
// alpha no other instrument has measured, read back as PAINTED PIXELS.
// Task 01a1557a-8f80 stage 4.
//
// Run: `mix assets.build` (the probe paints priv/static/assets/css/app.css),
// then your own headless Chrome with the colour-profile flag, which is not
// optional (without it the screenshot bytes are colour-managed):
//   "<chrome>" --headless=new --remote-debugging-port=<port> \
//     --force-color-profile=srgb --allow-file-access-from-files \
//     --user-data-dir=<scratch dir> --hide-scrollbars
//   CDP_PORT=<port> node probe.mjs        # writes results.json beside it
// The guard reads results.json; commit it with the change that moved it.
//
// The sheets' text pairs and opaque fills are held by
// test/platform/design/agents_members_sheets_contrast_guard_test.exs with the
// same method as every other sheet guard (opaque tokens, and --subtle painted
// on the PaintedComposite envelope). Two controls on these sheets do not fit
// that method, because daisyUI composites them at a strength PaintedComposite
// has never been measured at:
//
//   * the OFF switch: `.toggle` paints its border and knob in
//     color-mix(in oklab, base-content 50%, transparent);
//   * the unselected radio: `.radio` paints its ring in
//     color-mix(in srgb, currentColor 20%, transparent) unless a utility sets
//     the border colour (the sheet now sets `border-subtle`; run with
//     RADIO_CLASS="radio radio-sm text-base-content" to read daisyUI's own).
//
// So this script paints the shipped class lists over base-100 and base-200 in
// all ten variants and reads each indicator back from a screenshot. Every
// value recorded is a screenshot byte. Nothing is read off a declaration,
// except to record WHICH declarations each reading was taken under, so the
// guard can tell a stale reading from a current one.
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isolatedPage } from "../01a0cf85-dark-token-diff/cdp.mjs";
import { decodePng } from "../01a0cf85-dark-token-diff/png.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = resolve(HERE, "../../..");
const CSS = join(APP_ROOT, "priv/static/assets/css/app.css");
const OUT = process.env.OUT || join(HERE, "results.json");
const PLANTED = [123, 63, 29]; // #7B3F1D, in no palette

const VARIANTS = [
  ["burrow", "light"],
  ["burrow", "dark"],
  ["burrow-midnight", "light"],
  ["burrow-midnight", "dark"],
  ["burrow-sand", "light"],
  ["burrow-sand", "dark"],
  ["burrow-forest", "light"],
  ["burrow-forest", "dark"],
  ["high-contrast", "light"],
  ["high-contrast", "dark"],
  // Sage (task 01a19555 stage 2).
  ["sage", "light"],
  ["sage", "dark"],
];
const GROUNDS = ["base-100", "base-200"];

// The class lists the sheets ship (agents_sheet.ex, members_component.ex).
// The guard asserts each of these strings is still in the source.
const SAMPLES = {
  switch_off: `<input type="checkbox" role="switch" class="${process.env.SWITCH_CLASS || "toggle toggle-primary"}">`,
  switch_on: `<input type="checkbox" role="switch" checked class="${process.env.SWITCH_CLASS || "toggle toggle-primary"}">`,
  radio_off: `<input type="radio" class="${process.env.RADIO_CLASS || "radio radio-sm border-subtle text-base-content"}">`,
  radio_on: `<input type="radio" checked class="${process.env.RADIO_CLASS || "radio radio-sm border-subtle text-base-content"}">`,
};

function die(msg) {
  console.error(`ABORT: ${msg}`);
  process.exit(1);
}

const lin = (c) => {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
};
const lum = ([r, g, b]) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
const contrast = (a, b) => {
  const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};
const hex = (p) => "#" + p.slice(0, 3).map((v) => v.toString(16).padStart(2, "0")).join("");

function themeAttrs(id, mode) {
  return id === "burrow" ? `data-theme="${mode}"` : `data-preset="${id}" data-theme="${mode}"`;
}

function page() {
  const cells = [];
  VARIANTS.forEach(([id, mode], vi) => {
    GROUNDS.forEach((g, gi) => {
      const items = Object.entries(SAMPLES)
        .map(
          ([k, html]) =>
            `<span data-probe="${vi}|${g}|${k}" style="display:inline-flex;margin:8px">${html}</span>`,
        )
        .join("");
      cells.push(
        `<div ${themeAttrs(id, mode)} class="bg-${g}" style="padding:12px;display:flex;align-items:center">` +
          `<span data-probe="${vi}|${g}|ground" class="bg-${g}" style="display:inline-block;width:12px;height:12px"></span>` +
          `<span data-probe="${vi}|${g}|planted" style="display:inline-block;width:12px;height:12px;background:${hex(PLANTED)}"></span>` +
          items +
          `</div>`,
      );
    });
  });
  return (
    `<!doctype html><html><head><meta charset="utf-8">` +
    `<link rel="stylesheet" href="${pathToFileURL(CSS)}"></head>` +
    `<body style="margin:0">${cells.join("")}</body></html>`
  );
}

const dir = mkdtempSync(join(tmpdir(), "r8s4-probe-"));
const file = join(dir, "probe.html");
writeFileSync(file, page());

const W = 600;
// A cell lays out at ~60.3px, so 60 per cell clipped the 24th (Sage,
// task 01a19555 stage 2); 62 leaves room.
const H = VARIANTS.length * GROUNDS.length * 62;
const p = await isolatedPage(W, H);
await p.navigate(pathToFileURL(file).href);

const rects = await p.evaluate(`
  [...document.querySelectorAll('[data-probe]')].map(e => {
    const r = (e.firstElementChild || e).getBoundingClientRect();
    return { key: e.dataset.probe, x: r.x, y: r.y, w: r.width, h: r.height };
  })
`);
const shot = await p.S("Page.captureScreenshot", {
  format: "png",
  clip: { x: 0, y: 0, width: W, height: H, scale: 1 },
  captureBeyondViewport: true,
});
await p.close();
const img = decodePng(Buffer.from(shot.data, "base64"));
const at = (x, y) => img.pixel(Math.round(x), Math.round(y)).slice(0, 3);

const byKey = Object.fromEntries(rects.map((r) => [r.key, r]));
const centre = (r) => at(r.x + r.w / 2, r.y + r.h / 2);

// The indicator: of every pixel in the control's box, the one with the most
// contrast against the ground. A flat fill paints its own colour on every
// covered pixel and antialiasing only moves a pixel toward the ground, so the
// extreme pixel IS the indicator colour. The modal non-ground colour is kept
// beside it as a check.
function indicator(r, ground) {
  let best = ground;
  let bestC = 1;
  const counts = new Map();
  for (let y = Math.ceil(r.y); y < r.y + r.h; y++) {
    for (let x = Math.ceil(r.x); x < r.x + r.w; x++) {
      const px = at(x, y);
      const c = contrast(px, ground);
      if (c > bestC) [best, bestC] = [px, c];
      if (hex(px) !== hex(ground)) counts.set(hex(px), (counts.get(hex(px)) || 0) + 1);
    }
  }
  const modal = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
  return { painted: hex(best), ratio: +bestC.toFixed(4), modal: modal ? modal[0] : null };
}

const readings = [];
VARIANTS.forEach(([id, mode], vi) => {
  GROUNDS.forEach((g) => {
    const ground = centre(byKey[`${vi}|${g}|ground`]);
    const planted = centre(byKey[`${vi}|${g}|planted`]);
    if (hex(planted) !== hex(PLANTED)) die(`planted control read ${hex(planted)} in ${id} ${mode}`);
    const row = { variant: `${id} ${mode}`, ground: g, ground_painted: hex(ground) };
    for (const k of Object.keys(SAMPLES)) row[k] = indicator(byKey[`${vi}|${g}|${k}`], ground);
    readings.push(row);
  });
});

// Two variants must not paint the same ground, or the theme attributes
// did not apply (an instrument miss, not a reading).
const grounds = new Set(readings.filter((r) => r.ground === "base-100").map((r) => r.ground_painted));
if (grounds.size < 6) die(`only ${grounds.size} distinct base-100 grounds: themes did not apply`);

const css = readFileSync(CSS, "utf8");
writeFileSync(
  OUT,
  JSON.stringify(
    {
      task: "01a1557a-8f80-7000-9ee4-40b29760da18 stage 4",
      browser: p.version,
      flags: "--headless=new --force-color-profile=srgb, deviceScaleFactor 1",
      css_bytes: css.length,
      classes: SAMPLES,
      readings,
    },
    null,
    2,
  ) + "\n",
);
console.log(`wrote ${OUT}`);
for (const r of readings) {
  console.log(
    `${r.variant.padEnd(22)} ${r.ground}  off ${r.switch_off.ratio}  on ${r.switch_on.ratio}  radio_off ${r.radio_off.ratio}  radio_on ${r.radio_on.ratio}`,
  );
}
