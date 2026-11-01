// Paints the rows of the theme-variant fixtures the design guards read
// (task 01a19555-1ed2-7000-bd9a-e743874c5ac0 stage 1), so a new preset can be
// painted by the same instrument that reproduces the committed rows.
//
//   node paint.mjs --out <dir> \
//     --build chrome151=127.0.0.1:<port> --build chrome147=127.0.0.1:<port> \
//     [--css <compiled app.css>] [--only glass,ring,underlay,tokens] \
//     <variant>... | all
//
// A variant is `<preset>:<mode>` (`burrow:light`, `burrow-sand:dark`); `all`
// is the ten committed variants in fixture order. Without --css the harness
// compiles assets/css/app.css with the Tailwind standalone binary first.
// README.md says how to start the two pinned browsers (run.sh does it all).
//
// Written to <dir>, each with a `#` header and the fixture's own column line,
// rows in the fixture's order:
//   <build>.csv            test/support/fixtures/painted_glass/chrome151.csv, chrome147.csv
//   underlay_<build>.csv   .../painted_glass/underlay_chrome151.csv, underlay_chrome147.csv
//   focus_ring.csv         .../painted_glass/focus_ring.csv (every build, in --build order)
//   <build>_tokens.csv     .../painted_mix/chrome151_tokens.csv, chrome147_tokens.csv
//
// Every value is a screenshot byte (Page.captureScreenshot, PNG, DPR 1) read
// at the centre of a flat patch. Nothing is computed from a declaration.
// Transitions and animations are switched off, so each row is the settled
// paint of its own state, not a frame of the move from the previous one.
//
// GLASS_MIX (env, default "srgb") is the named mutation: the compiled CSS's
// glass declarations, `color-mix(in srgb, var(--color-base-200)
// calc(var(--glass-alpha) * 100%), transparent)`, are rewritten to that space
// before painting. At "srgb" the rewrite is the identity (asserted).
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isolatedPage } from "./cdp.mjs";
import { decodePng } from "../01a0cf85-dark-token-diff/png.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = resolve(HERE, "../../..");

// ── arguments ───────────────────────────────────────────────────────────────

const ALL = [
  "burrow:light",
  "burrow:dark",
  "burrow-midnight:light",
  "burrow-midnight:dark",
  "burrow-sand:light",
  "burrow-sand:dark",
  "burrow-forest:light",
  "burrow-forest:dark",
  "high-contrast:light",
  "high-contrast:dark",
];
const SLOTS = ["teal", "blue", "purple", "rose", "amber", "green", "orange", "indigo", "brick", "lime"];
const UNDERLAYS = [
  ["black", "#000"],
  ["white", "#fff"],
  ["base_content", "var(--color-base-content)"],
  ["base_100", "var(--color-base-100)"],
  ["primary", "var(--color-primary)"],
  ...SLOTS.map((s) => [`ag_${s}`, `var(--ag-${s})`]),
];

function die(msg) {
  console.error(`ABORT: ${msg}`);
  process.exit(1);
}

const args = process.argv.slice(2);
const opts = { builds: [], variants: [], only: ["glass", "ring", "underlay", "tokens"] };
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--out") opts.out = resolve(args[++i]);
  else if (a === "--css") opts.css = resolve(args[++i]);
  else if (a === "--only") opts.only = args[++i].split(",");
  else if (a === "--build") {
    const [name, host] = args[++i].split("=");
    if (!/^chrome\d+$/.test(name) || !host) die(`--build wants chromeNNN=host:port, got ${args[i]}`);
    opts.builds.push({ name, host });
  } else if (a === "all") opts.variants.push(...ALL);
  else if (/^[a-z0-9-]+:(light|dark)$/.test(a)) opts.variants.push(a);
  else die(`unknown argument ${a}`);
}
if (!opts.out) die("--out <dir> is required");
if (opts.builds.length === 0) die("at least one --build is required");
if (opts.variants.length === 0) die("name variants (`burrow:light` ...) or `all`");
mkdirSync(opts.out, { recursive: true });

const variants = opts.variants.map((v) => {
  const [preset, mode] = v.split(":");
  return { preset, mode, label: `${preset} ${mode}` };
});

// ── the stylesheet ──────────────────────────────────────────────────────────

function compile() {
  const plat = { darwin: "macos", linux: "linux" }[process.platform] || die("unsupported OS");
  const arch = { arm64: "arm64", x64: "x64" }[process.arch] || die("unsupported arch");
  const bin = process.env.TAILWIND || join(APP_ROOT, `_build/tailwind-${plat}-${arch}`);
  if (!existsSync(bin)) die(`no Tailwind binary at ${bin}; set TAILWIND or run mix tailwind.install`);
  const out = join(opts.out, "app.css");
  execFileSync(bin, ["--input=assets/css/app.css", `--output=${out}`], {
    cwd: APP_ROOT,
    stdio: ["ignore", "ignore", "inherit"],
  });
  return out;
}

const cssPath = opts.css || compile();
const compiled = readFileSync(cssPath, "utf8");
const cssSha = createHash("sha256").update(compiled).digest("hex");

const GLASS_MIX = process.env.GLASS_MIX || "srgb";
const GLASS_DECL = "color-mix( in srgb, var(--color-base-200) calc(var(--glass-alpha) * 100%), transparent )";
const glassCount = compiled.split(GLASS_DECL).length - 1;
if (glassCount < 1) die("the compiled CSS holds no glass declaration to paint");
const css = compiled.split(GLASS_DECL).join(GLASS_DECL.replace("in srgb", `in ${GLASS_MIX}`));
if (GLASS_MIX === "srgb" && css !== compiled) die("the srgb rewrite is not the identity");

// Settled paint only: no transition or animation frame can be captured.
const HARNESS_CSS =
  "*, *::before, *::after { transition: none !important; animation: none !important; }";

function themeAttrs({ preset, mode }) {
  return preset === "burrow" ? `data-theme="${mode}"` : `data-preset="${preset}" data-theme="${mode}"`;
}

function doc(rootAttrs, body) {
  return (
    `<!doctype html><html ${rootAttrs}><head><meta charset="utf-8">` +
    `<style>${css}</style><style>${HARNESS_CSS}</style></head>` +
    `<body style="margin:0">${body}</body></html>`
  );
}

// ── reading pixels ──────────────────────────────────────────────────────────

const hex = (p) => p.slice(0, 3).map((v) => v.toString(16).padStart(2, "0")).join("");

// Screenshot the viewport and read the centre pixel of every [data-k]
// element, keyed "<cell>|<k>".
async function read(page, W, H) {
  await page.evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))");
  const points = await page.evaluate(`
    [...document.querySelectorAll('[data-k]')].map(e => {
      const r = e.getBoundingClientRect();
      const cell = e.closest('[data-cell]');
      return { key: (cell ? cell.dataset.cell : '') + '|' + e.dataset.k,
               x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
    })`);
  // One capture per [data-cell] (the whole viewport when there is none): a
  // single 900x4500 capture outgrew the GPU process's copy-out on Chrome 151
  // and timed out. A clip only crops the composited frame.
  const cells = await page.evaluate(`
    (() => {
      const cs = [...document.querySelectorAll('[data-cell]')];
      if (cs.length === 0 || cs.some(c => c.parentElement.closest('[data-cell]'))) return null;
      return cs.map(c => { const r = c.getBoundingClientRect();
        return { x: Math.floor(r.x), y: Math.floor(r.y), w: Math.ceil(r.width), h: Math.ceil(r.height) }; });
    })()`);
  const clips = cells || [{ x: 0, y: 0, w: W, h: H }];
  const out = {};
  for (const c of clips) {
    if (c.x < 0 || c.y < 0 || c.x + c.w > W || c.y + c.h > H) die(`cell ${JSON.stringify(c)} is outside the ${W}x${H} viewport`);
    // A capture is deterministic, so a capture that timed out (a loaded host,
    // seen once on the software path) is simply taken again, at most twice.
    let shot;
    for (let attempt = 1; !shot; attempt++) {
      try {
        shot = await page.S("Page.captureScreenshot", {
          format: "png",
          clip: { x: c.x, y: c.y, width: c.w, height: c.h, scale: 1 },
        });
      } catch (e) {
        if (attempt >= 3 || !String(e.message).startsWith("timeout")) throw e;
        console.error(`  capture timed out (attempt ${attempt}); retrying`);
      }
    }
    const img = decodePng(Buffer.from(shot.data, "base64"));
    for (const p of points) {
      if (p.x < c.x || p.x >= c.x + c.w || p.y < c.y || p.y >= c.y + c.h) continue;
      if (p.w < 4 || p.h < 4) die(`patch ${p.key} is ${p.w}x${p.h}; nothing to read`);
      out[p.key] = hex(img.pixel(Math.floor(p.x) - c.x, Math.floor(p.y) - c.y));
    }
  }
  for (const p of points) if (!(p.key in out)) die(`patch ${p.key} lies outside every capture`);
  return out;
}

const pick = (px, cell, keys) =>
  keys.map((k) => {
    const v = px[`${cell}|${k}`];
    if (v === undefined) die(`no reading for ${cell}|${k}`);
    return `#${v}`;
  });

const controls = `
  <span data-k="ctl_white" style="position:absolute;left:4px;top:4px;width:10px;height:10px;background:#fff"></span>
  <span data-k="ctl_black" style="position:absolute;left:18px;top:4px;width:10px;height:10px;background:#000"></span>`;

const flat = (k, bg, extra = "") =>
  `<span data-k="${k}" style="display:block;width:20px;height:10px;${extra}background:${bg}"></span>`;

// The tab bar with flat patches. `contain: paint` on the enclosing cell makes
// the cell the containing block of the fixed-position bar.
function bar({ alpha, ring }) {
  const style = alpha === undefined ? "" : ` style="--glass-alpha:${alpha}"`;
  return `
  <nav class="bottom-nav"${style}>
    <a class="bottom-nav-tab">
      <span class="bottom-nav-icon size-5" data-k="inactive_icon" style="display:block;background:currentColor"></span>
      <span class="bottom-nav-label" data-k="inactive_label" style="display:block;width:24px;height:11px;background:currentColor"></span>
    </a>
    <a class="bottom-nav-tab bottom-nav-tab--active">
      <span class="bottom-nav-icon size-5" data-k="active_icon" style="display:block;background:currentColor"></span>
      <span class="bottom-nav-label" data-k="active_label" style="display:block;width:24px;height:11px;background:currentColor"></span>
    </a>
    <a class="bottom-nav-tab">
      <span class="bottom-nav-dot" data-k="dot"></span>
      ${flat("subtle", "var(--color-subtle)")}
    </a>
    <a class="bottom-nav-tab">${ring ? flat("ring", "var(--color-focus-ring)") : ""}</a>
    <a class="bottom-nav-tab"><span data-k="glass" style="display:block;width:20px;height:10px"></span></a>
  </nav>`;
}

function cell(name, bg, h, inner) {
  return (
    `<div data-cell="${name}" style="position:relative;contain:paint;overflow:hidden;` +
    `width:100%;height:${h}px;background:${bg}">${controls}${inner}</div>`
  );
}

// ── the four sweeps ─────────────────────────────────────────────────────────

const GLASS_COLS = "glass inactive_icon inactive_label active_icon active_label dot subtle ctl_white ctl_black".split(" ");
const alphas = (from, to) => {
  const out = [];
  for (let i = from; i <= to; i++) out.push((i / 100).toFixed(2));
  return out;
};

async function glass(page) {
  const W = 400;
  const H = 240;
  await page.resize(W, H);
  const rows = [];
  for (const v of variants) {
    const body = ["black", "white"].map((bd) => cell(bd, bd === "black" ? "#000" : "#fff", 120, bar({}))).join("");
    await page.setContent(doc(themeAttrs(v), body));
    for (const a of alphas(50, 100)) {
      await page.evaluate(
        `document.querySelectorAll('.bottom-nav').forEach(n => n.style.setProperty('--glass-alpha', '${a}'))`,
      );
      const px = await read(page, W, H);
      for (const bd of ["black", "white"]) rows.push([v.label, bd, a, ...pick(px, bd, GLASS_COLS)].join(","));
    }
  }
  return rows;
}

async function ring(page, build) {
  const W = 400;
  const H = 240;
  await page.resize(W, H);
  const rows = [];
  for (const v of variants) {
    const body = ["black", "white"].map((bd) => cell(bd, bd === "black" ? "#000" : "#fff", 120, bar({ ring: true }))).join("");
    await page.setContent(doc(themeAttrs(v), body));
    const declared = await page.evaluate(
      `getComputedStyle(document.querySelector('.bottom-nav')).getPropertyValue('--glass-alpha').trim()`,
    );
    if (!declared) die(`${v.label}: no --glass-alpha on the bar`);
    const px = await read(page, W, H);
    for (const bd of ["black", "white"]) {
      rows.push([build, v.label, bd, declared, ...pick(px, bd, ["glass", "ring", "ctl_white", "ctl_black"])].join(","));
    }
  }
  return rows;
}

const UNDER_COLS =
  "bar_glass inactive_icon inactive_label active_icon active_label dot pill_glass placeholder typed attach send band_glass typing ctl_white ctl_black".split(
    " ",
  );

// The phone dock (typing band + composer pill) and the tab bar, each over a
// flat underlay. The dock is lifted clear of the bar so no glass overlaps
// another; each surface's backdrop is the underlay alone.
function underCell(name, bg) {
  const dock = `
  <div id="chat-drop-zone" style="position:absolute;inset:0">
    <div class="chat-dock chat-dock--glass" style="bottom:110px;padding-bottom:0">
      <div data-role="typing-indicator" class="flex-shrink-0 px-5 pb-1 items-center gap-2 text-xs text-subtle flex">
        ${flat("typing", "currentColor")}
        <span data-k="band_glass" style="display:block;width:20px;height:10px"></span>
      </div>
      <div class="flex-shrink-0 compose-input-area safe-area-bottom">
        <div class="compose-pill-bar">
          <button type="button" class="compose-pill-attach cursor-pointer text-subtle">${flat("attach", "currentColor")}</button>
          <div class="compose-field" style="display:flex;gap:12px;align-items:center">
            ${flat("placeholder", "var(--color-subtle)")}
            ${flat("typed", "currentColor")}
            <span data-k="pill_glass" style="display:block;width:20px;height:10px"></span>
          </div>
          <button type="button" class="compose-pill-send"><span data-k="send" style="display:block;width:6px;height:6px"></span></button>
        </div>
      </div>
    </div>
  </div>`;
  return cell(name, bg, 300, dock + bar({}).replace("data-k=\"glass\"", "data-k=\"bar_glass\""));
}

async function underlay(page) {
  const W = 900;
  const H = 300 * UNDERLAYS.length;
  await page.resize(W, H);
  const rows = [];
  for (const v of variants) {
    await page.setContent(doc(themeAttrs(v), UNDERLAYS.map(([n, bg]) => underCell(n, bg)).join("")));
    for (const a of alphas(80, 100)) {
      await page.evaluate(
        `document.querySelectorAll('.bottom-nav, .compose-pill-bar, [data-role="typing-indicator"]').forEach(n => n.style.setProperty('--glass-alpha', '${a}'))`,
      );
      const px = await read(page, W, H);
      for (const [u] of UNDERLAYS) rows.push([v.label, u, a, ...pick(px, u, UNDER_COLS)].join(","));
    }
  }
  return rows;
}

// The opaque agent tints, `var(--ag-<id>-tint)`, at each block's declared
// strength: an 8x8 and a 10x20 box, with the theme on the page root and on a
// child of a page themed otherwise (Burrow dark, or Burrow light for it).
async function tokens(page) {
  const W = 400;
  const H = 400;
  await page.resize(W, H);
  const rows = [];
  const boxes = (prefix) =>
    SLOTS.map(
      (s) =>
        `<div style="display:flex;gap:4px;margin:2px">` +
        `<span data-k="${prefix}small|${s}" style="display:block;width:8px;height:8px;background:var(--ag-${s}-tint)"></span>` +
        `<span data-k="${prefix}block|${s}" style="display:block;width:10px;height:20px;background:var(--ag-${s}-tint)"></span>` +
        `<span data-k="${prefix}ink|${s}" style="display:block;width:8px;height:8px;background:var(--ag-${s})"></span>` +
        `</div>`,
    ).join("") +
    `<span data-k="${prefix}ground" style="display:block;width:8px;height:8px;background:var(--color-base-100)"></span>`;

  for (const v of variants) {
    await page.setContent(doc(themeAttrs(v), boxes("root_")));
    const root = await read(page, W, H);
    const pct = await page.evaluate(
      `getComputedStyle(document.documentElement).getPropertyValue('--ag-tint-pct').trim()`,
    );
    const m = /^(\d+)%$/.exec(pct) || die(`${v.label}: --ag-tint-pct is ${JSON.stringify(pct)}`);

    const other = v.preset === "burrow" && v.mode === "dark" ? { preset: "burrow", mode: "light" } : { preset: "burrow", mode: "dark" };
    await page.setContent(doc(themeAttrs(other), `<div ${themeAttrs(v)}>${boxes("nested_")}</div>`));
    const nested = await read(page, W, H);
    const px = { ...root, ...nested };

    const ground = px["|root_ground"];
    for (const s of SLOTS) {
      for (const path of ["block_nested", "block_root", "small_nested", "small_root"]) {
        const [size, where] = path.split("_");
        rows.push([v.preset, v.mode, s, "tint", px[`|root_ink|${s}`], ground, m[1], path, px[`|${where}_${size}|${s}`]]);
      }
    }
  }
  // The fixture's order: preset, mode, slot, path, each compared as a string.
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  rows.sort((a, b) => cmp(a[0], b[0]) || cmp(a[1], b[1]) || cmp(a[2], b[2]) || cmp(a[7], b[7]));
  return rows.map((r) => r.join(","));
}

// ── run ─────────────────────────────────────────────────────────────────────

const header = (b, what) =>
  [
    `# build: ${b.version} -- ${b.host}`,
    `# user-agent: ${b.userAgent}`,
    `# ${what}, painted by apps/platform/priv/measurements/01a19555-preset-paint/paint.mjs`,
    `# (task 01a19555-1ed2-7000-bd9a-e743874c5ac0). Compiled app.css sha256 ${cssSha}; glass mix ${GLASS_MIX} (${glassCount} declarations).`,
    `# Variants: ${variants.map((v) => v.label).join(", ")}.`,
  ].join("\n");

const ringRows = [];
const ringHeads = [];
for (const b of opts.builds) {
  const page = await isolatedPage(b.host, 400, 240);
  Object.assign(b, { version: page.version, userAgent: page.userAgent });
  console.error(`${b.name}: ${page.version} at ${b.host}`);
  try {
    if (opts.only.includes("glass")) {
      const rows = await glass(page);
      const cols = "variant,backdrop,alpha," + GLASS_COLS.join(",");
      writeFileSync(join(opts.out, `${b.name}.csv`), [header(b, "Painted glass sweep"), cols, ...rows].join("\n") + "\n");
      console.error(`  glass: ${rows.length} rows`);
    }
    if (opts.only.includes("underlay")) {
      const rows = await underlay(page);
      const cols = "variant,underlay,alpha," + UNDER_COLS.join(",");
      writeFileSync(join(opts.out, `underlay_${b.name}.csv`), [header(b, "Painted under-glass sweep"), cols, ...rows].join("\n") + "\n");
      console.error(`  underlay: ${rows.length} rows`);
    }
    if (opts.only.includes("tokens")) {
      const rows = await tokens(page);
      const cols = "# preset,mode,slot,token,ink,ground,strength,path,pixel";
      writeFileSync(join(opts.out, `${b.name}_tokens.csv`), [header(b, "Painted agent tint tokens"), cols, ...rows].join("\n") + "\n");
      console.error(`  tokens: ${rows.length} rows`);
    }
    if (opts.only.includes("ring")) {
      ringRows.push(...(await ring(page, b.name)));
      ringHeads.push(header(b, "Painted focus ring"));
    }
  } finally {
    await page.close();
  }
}
if (opts.only.includes("ring")) {
  const cols = "build,variant,backdrop,alpha,glass,ring,ctl_white,ctl_black";
  writeFileSync(join(opts.out, "focus_ring.csv"), [...ringHeads, cols, ...ringRows].join("\n") + "\n");
  console.error(`focus_ring: ${ringRows.length} rows`);
}
console.error(`wrote ${opts.out} (app.css sha256 ${cssSha})`);
process.exit(0);
