// Dark-theme token diff, live Suite vs the meetings mock, by PAINTED PIXEL.
// Task 01a0cf85. See README.md for how to run it.
//
// Every value this script records is a byte read back from a screenshot of a
// swatch the browser painted. Nothing is read off a CSS declaration, a
// getComputedStyle string or an app.css comment. The app.css declarations are
// read ONLY to record which declaration each live reading was taken from, so
// the ExUnit staleness guard can tell when a reading has gone out of date.
//
// The run aborts non-zero if any instrument control misses. Controls run on
// each page BEFORE any token on that page is read.
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import { isolatedPage } from "./cdp.mjs";
import { decodePng } from "./png.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = resolve(HERE, "../../..");
const REPO_ROOT = resolve(APP_ROOT, "../..");

const LIVE_URL = process.env.LIVE_URL;
const LIVE_USER = process.env.LIVE_USER || "tokenprobe";
const MOCK_HTML = process.env.MOCK_HTML;
const OUT = process.env.OUT || join(HERE, "results.json");
const GIT = process.env.GIT_BIN || "git";

const W = 800;
const H = 900;
const COLS = 18;
const PLANTED = "#7B3F1D"; // in neither palette: `git grep -i 7b3f1d` is empty
const UNDER_A = "#FF00FF";
const UNDER_B = "#00FF00";

function die(msg) {
  console.error(`ABORT: ${msg}`);
  process.exit(1);
}

if (!LIVE_URL) die("LIVE_URL is required (the dev server on this branch)");
if (!MOCK_HTML || !isAbsolute(MOCK_HTML)) die("MOCK_HTML must be an absolute path");
if (!relative(REPO_ROOT, MOCK_HTML).startsWith("..")) {
  die("MOCK_HTML is inside the repo. The mock is never committed; keep it outside.");
}

// ── swatch recipes ───────────────────────────────────────────────────────

const bg = (v) => `background-color:${v}`;

const LIVE = {
  rows: {
    "base-100": { paint: bg("var(--color-base-100)"), decl: "--color-base-100" },
    "base-200": { paint: bg("var(--color-base-200)"), decl: "--color-base-200" },
    "base-300": { paint: bg("var(--color-base-300)"), decl: "--color-base-300" },
    edge: { paint: bg("var(--edge)"), decl: "--edge" },
    "base-content": { paint: bg("var(--color-base-content)"), decl: "--color-base-content" },
    // No dark text-muted token exists. The live counterpart is the shipped
    // Tailwind utility itself, painted through currentColor so the browser
    // resolves the class exactly as it does on a real element.
    muted: {
      paint: bg("currentColor"),
      className: "text-base-content/60",
      decl: "--color-base-content",
      translucent: true,
    },
    faint: {
      paint: bg("currentColor"),
      className: "text-base-content/40",
      decl: "--color-base-content",
      translucent: true,
    },
    primary: { paint: bg("var(--color-primary)"), decl: "--color-primary" },
    info: { paint: bg("var(--color-info)"), decl: "--color-info" },
    success: { paint: bg("var(--color-success)"), decl: "--color-success" },
    warning: { paint: bg("var(--color-warning)"), decl: "--color-warning" },
    error: { paint: bg("var(--color-error)"), decl: "--color-error" },
  },
  // The -content tokens, read so each fill can be measured against the
  // text daisyUI puts on it.
  extras: {
    "primary-content": { paint: bg("var(--color-primary-content)"), decl: "--color-primary-content" },
    "info-content": { paint: bg("var(--color-info-content)"), decl: "--color-info-content" },
    "success-content": { paint: bg("var(--color-success-content)"), decl: "--color-success-content" },
    "warning-content": { paint: bg("var(--color-warning-content)"), decl: "--color-warning-content" },
    "error-content": { paint: bg("var(--color-error-content)"), decl: "--color-error-content" },
  },
  grounds: {
    "base-100": bg("var(--color-base-100)"),
    "base-200": bg("var(--color-base-200)"),
  },
  translucentOver: ["base-100", "base-200"],
  textGrounds: ["base-100", "base-200"],
  extraPairs: [
    ["base-content", "base-300"],
    ["primary", "base-300"],
    ["primary-content", "primary"],
    ["info-content", "info"],
    ["success-content", "success"],
    ["warning-content", "warning"],
    ["error-content", "error"],
  ],
};

const MOCK = {
  rows: {
    "base-100": { paint: bg("var(--base-100)"), decl: "--base-100" },
    "base-200": { paint: bg("var(--base-200)"), decl: "--base-200" },
    "base-300": { paint: bg("var(--base-300)"), decl: "--base-300" },
    // The mock has no separate edge token: every border is var(--base-300).
    edge: { paint: bg("var(--base-300)"), decl: "--base-300" },
    "base-content": { paint: bg("var(--content)"), decl: "--content" },
    muted: { paint: bg("var(--muted)"), decl: "--muted", translucent: true },
    faint: { paint: bg("var(--faint)"), decl: "--faint", translucent: true },
    primary: { paint: bg("var(--primary)"), decl: "--primary" },
    info: { paint: bg("var(--info)"), decl: "--info" },
    success: { paint: bg("var(--success)"), decl: "--success" },
    // No --warning token. Expected to come back unresolved; the fallback the
    // mock actually paints is read separately below.
    warning: { paint: bg("var(--warning)"), decl: "--warning" },
    error: { paint: bg("var(--error)"), decl: "--error" },
  },
  extras: {
    "warning-fallback": { paint: bg("var(--warning,#f59e0b)"), decl: "var(--warning,#f59e0b)" },
    // The mock has no -content tokens. The one text-on-info pairing it ships
    // is the held Ask button: .ask.held { background: var(--info); color: #0b1220 }.
    "info-content": { paint: bg("#0b1220"), decl: ".ask.held color #0b1220" },
  },
  grounds: {
    "base-100": bg("var(--base-100)"),
    "base-200": bg("var(--base-200)"),
    card: bg("#12161f"),
  },
  translucentOver: ["base-100", "card"],
  textGrounds: ["base-100", "base-200", "card"],
  extraPairs: [
    ["base-content", "base-300"],
    ["primary", "base-300"],
    ["info-content", "info"],
  ],
};

const TEXT_ROWS = ["base-content", "primary", "info", "success", "warning", "error"];
const SEPARATIONS = [
  ["base-100", "base-200"],
  ["edge", "base-100"],
  ["base-300", "base-100"],
  ["base-300", "base-200"],
];

// ── byte helpers ─────────────────────────────────────────────────────────

const hex = ([r, g, b]) =>
  "#" + [r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("").toUpperCase();
const lin = (c) => {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
};
const lum = (h) => {
  const n = parseInt(h.slice(1), 16);
  return 0.2126 * lin((n >> 16) & 255) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
};
const ratio = (a, b) => {
  const [la, lb] = [lum(a), lum(b)];
  return Math.round(((Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)) * 10000) / 10000;
};

// ── the reader ───────────────────────────────────────────────────────────

// Paints every spec into one fixed overlay, screenshots once, and reads each
// swatch's interior back as bytes. Returns {id: {ok, hex?, reason?}}.
async function paintAndRead(page, specs) {
  const rects = await page.evaluate(`(${paintInPage.toString()})(${JSON.stringify(specs)}, ${COLS})`);
  const shot = await page.S("Page.captureScreenshot", { format: "png", fromSurface: true });
  const png = decodePng(Buffer.from(shot.data, "base64"));
  const out = {};

  for (const s of specs) {
    const r = rects[s.id];
    const x0 = Math.round(r.x) + 4;
    const y0 = Math.round(r.y) + 4;
    if (r.x < 0 || r.y < 0 || r.x + r.w > png.width || r.y + r.h > png.height || r.w < 16) {
      out[s.id] = { ok: false, reason: `swatch box outside the captured viewport (${r.x},${r.y})` };
      continue;
    }
    const seen = new Set();
    let px;
    for (let y = y0; y < y0 + 8; y++)
      for (let x = x0; x < x0 + 8; x++) {
        px = png.pixel(x, y);
        seen.add(hex(px));
      }
    out[s.id] =
      seen.size === 1
        ? { ok: true, hex: [...seen][0] }
        : { ok: false, reason: `swatch interior not uniform: ${[...seen].slice(0, 4).join(",")}` };
  }
  return out;
}

// Runs in the page. Fresh elements every time: an invalid declaration in a
// fresh style attribute is DROPPED, so there is no previous value for it to
// silently keep.
function paintInPage(specs, cols) {
  document.getElementById("__tokprobe")?.remove();
  const root = document.createElement("div");
  root.id = "__tokprobe";
  root.setAttribute(
    "style",
    "position:fixed;inset:0;z-index:2147483647;background:#808080;isolation:isolate;" +
      "overflow:hidden;margin:0;padding:0;opacity:1;filter:none;transform:none;display:block;" +
      "transition:none;animation:none",
  );
  specs.forEach((s, i) => {
    const left = s.offscreen ? -4000 : 8 + (i % cols) * 40;
    const top = 8 + Math.floor(i / cols) * 40;
    const cell = document.createElement("div");
    cell.setAttribute(
      "style",
      `position:absolute;left:${left}px;top:${top}px;width:32px;height:32px;transition:none;${s.underlay}`,
    );
    const sw = document.createElement("div");
    sw.setAttribute(
      "style",
      `position:absolute;left:8px;top:8px;width:16px;height:16px;transition:none;animation:none;${s.paint}`,
    );
    if (s.className) sw.className = s.className;
    cell.appendChild(sw);
    root.appendChild(cell);
  });
  document.body.appendChild(root);
  return new Promise((res) =>
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        const out = {};
        specs.forEach((s, i) => {
          const r = root.children[i].firstChild.getBoundingClientRect();
          out[s.id] = { x: r.x, y: r.y, w: r.width, h: r.height };
        });
        res(out);
      }),
    ),
  );
}

// An opaque reading is TWO readings of the same paint over two different
// underlays. A painted opaque colour cannot depend on what is under it, so
// agreement is the proof the swatch painted; disagreement means the paint
// was dropped, transparent or unresolved, and the result is reported as
// unresolved rather than as the underlay's hex.
function opaqueSpecs(id, recipe) {
  return [UNDER_A, UNDER_B].map((u, i) => ({
    id: `${id}|${"AB"[i]}`,
    underlay: bg(u),
    paint: recipe.paint,
    className: recipe.className,
    offscreen: recipe.offscreen,
  }));
}

function resolveOpaque(readings, id) {
  const [a, b] = [readings[`${id}|A`], readings[`${id}|B`]];
  if (!a.ok) return { status: "unresolved", reason: a.reason };
  if (!b.ok) return { status: "unresolved", reason: b.reason };
  if (a.hex !== b.hex) {
    return {
      status: "unresolved",
      reason: `reads ${a.hex} over ${UNDER_A} but ${b.hex} over ${UNDER_B}: nothing opaque was painted`,
    };
  }
  return { status: "painted", hex: a.hex };
}

// The canvas leg for literal colours. A canvas KEEPS the previous fillStyle
// when a new assignment is invalid, so a single fill-and-read would report the
// previous colour. Each value is therefore filled twice, after resetting
// fillStyle to two different sentinels; if the readbacks differ the
// assignment did not take.
function canvasInPage(values, planted) {
  const c = document.createElement("canvas");
  c.width = 1;
  c.height = 1;
  const ctx = c.getContext("2d", { colorSpace: "srgb", willReadFrequently: true });
  const fill = (prev, v) => {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = prev;
    ctx.fillStyle = v;
    ctx.fillRect(0, 0, 1, 1);
    return Array.from(ctx.getImageData(0, 0, 1, 1).data);
  };
  const guarded = values.map((v) => [fill("#010203", v), fill("#FDFCFB", v)]);
  // The trap, reproduced on purpose: planted, then an invalid string.
  const naive = fill(planted, "not-a-colour");
  return { guarded, naive };
}

// ── controls ─────────────────────────────────────────────────────────────

async function runControls(page, side) {
  const dom = {
    white: { paint: bg("#FFFFFF"), expect: "#FFFFFF" },
    black: { paint: bg("#000000"), expect: "#000000" },
    planted: { paint: bg(PLANTED), expect: PLANTED },
    "undefined-var": { paint: bg("var(--nope)"), expect: null },
    "invalid-colour": { paint: bg("not-a-colour"), expect: null },
    offscreen: { paint: bg(PLANTED), offscreen: true, expect: null },
    unpainted: { paint: `${bg(PLANTED)};visibility:hidden`, expect: null },
  };
  const specs = Object.entries(dom).flatMap(([k, r]) => opaqueSpecs(`ctl-${k}`, r));
  // A composited reading's guard: var(--nope) over a real ground must read as
  // "painted nothing", never as the ground's hex.
  specs.push({ id: "ctl-nope-over-ground", underlay: bg(PLANTED), paint: bg("var(--nope)") });
  const readings = await paintAndRead(page, specs);

  const results = {};
  const misses = [];
  for (const [k, r] of Object.entries(dom)) {
    const got = resolveOpaque(readings, `ctl-${k}`);
    results[k] = got;
    if (r.expect && got.hex !== r.expect) misses.push(`${k}: expected ${r.expect}, got ${JSON.stringify(got)}`);
    if (!r.expect && got.status !== "unresolved") misses.push(`${k}: must be unresolved, got ${got.hex}`);
  }
  const overGround = readings["ctl-nope-over-ground"];
  results["undefined-var-over-ground"] =
    overGround.ok && overGround.hex === PLANTED
      ? { status: "unresolved", reason: "reads identical to its ground: nothing painted over it" }
      : { status: "unexpected", reading: overGround };
  if (results["undefined-var-over-ground"].status !== "unresolved") misses.push("undefined-var-over-ground");

  const canvasValues = ["#FFFFFF", "#000000", PLANTED, "not-a-colour"];
  const cv = await page.evaluate(
    `(${canvasInPage.toString()})(${JSON.stringify(canvasValues)}, ${JSON.stringify(PLANTED)})`,
  );
  const canvas = {};
  canvasValues.forEach((v, i) => {
    const [r1, r2] = cv.guarded[i];
    const h1 = hex(r1);
    const h2 = hex(r2);
    canvas[v] =
      h1 === h2 && r1[3] === 255
        ? { status: "painted", hex: h1 }
        : { status: "unresolved", reason: `readbacks ${h1} / ${h2} follow the sentinel: assignment ignored` };
  });
  canvas.naive_trap = { reads: hex(cv.naive), note: "planted then 'not-a-colour' with no guard" };
  results.canvas = canvas;

  if (canvas["#FFFFFF"].hex !== "#FFFFFF") misses.push("canvas white");
  if (canvas["#000000"].hex !== "#000000") misses.push("canvas black");
  if (canvas[PLANTED].hex !== PLANTED) misses.push("canvas planted");
  if (canvas["not-a-colour"].status !== "unresolved") misses.push("canvas invalid colour");
  if (canvas.naive_trap.reads !== PLANTED) misses.push("canvas trap did not reproduce; the guard proves nothing");

  if (misses.length) die(`${side} instrument controls missed:\n  ${misses.join("\n  ")}`);
  console.log(`${side}: all controls passed`);
  return results;
}

// ── tokens ───────────────────────────────────────────────────────────────

async function readSide(page, cfg) {
  const specs = [];
  const opaqueRows = Object.entries(cfg.rows).filter(([, r]) => !r.translucent);
  const translucentRows = Object.entries(cfg.rows).filter(([, r]) => r.translucent);

  for (const [k, r] of opaqueRows) specs.push(...opaqueSpecs(`row-${k}`, r));
  for (const [k, r] of Object.entries(cfg.extras || {})) specs.push(...opaqueSpecs(`extra-${k}`, r));
  for (const [k, g] of Object.entries(cfg.grounds)) specs.push(...opaqueSpecs(`ground-${k}`, { paint: g }));
  for (const [k, r] of translucentRows) {
    for (const g of cfg.translucentOver) {
      specs.push({ id: `row-${k}@${g}`, underlay: cfg.grounds[g], paint: r.paint, className: r.className });
    }
    // Diagnostic only: over black and over white gives the painted alpha.
    specs.push({ id: `row-${k}@K`, underlay: bg("#000000"), paint: r.paint, className: r.className });
    specs.push({ id: `row-${k}@W`, underlay: bg("#FFFFFF"), paint: r.paint, className: r.className });
  }

  const readings = await paintAndRead(page, specs);
  const grounds = {};
  for (const k of Object.keys(cfg.grounds)) grounds[k] = resolveOpaque(readings, `ground-${k}`);

  const rows = {};
  for (const [k, r] of opaqueRows) rows[k] = { recipe: r.paint, ...resolveOpaque(readings, `row-${k}`) };

  for (const [k, r] of translucentRows) {
    const over = {};
    for (const g of cfg.translucentOver) {
      const got = readings[`row-${k}@${g}`];
      const ground = grounds[g];
      over[g] = !got.ok
        ? { status: "unresolved", reason: got.reason }
        : ground.status !== "painted"
          ? { status: "unresolved", reason: `ground ${g} unresolved` }
          : got.hex === ground.hex
            ? { status: "unresolved", reason: "reads identical to its ground: nothing painted over it" }
            : { status: "painted", hex: got.hex };
    }
    const k0 = readings[`row-${k}@K`];
    const w0 = readings[`row-${k}@W`];
    let alpha = null;
    if (k0.ok && w0.ok) {
      const kb = parseInt(k0.hex.slice(1), 16);
      const wb = parseInt(w0.hex.slice(1), 16);
      const ch = (n, s) => (n >> s) & 255;
      const a = [16, 8, 0].map((s) => 1 - (ch(wb, s) - ch(kb, s)) / 255);
      alpha = {
        over_black: k0.hex,
        over_white: w0.hex,
        alpha_per_channel: a.map((v) => Math.round(v * 1000) / 1000),
      };
    }
    rows[k] = {
      recipe: r.className ? `class="${r.className}" + ${r.paint}` : r.paint,
      status: Object.values(over).every((o) => o.status === "painted") ? "painted" : "unresolved",
      over,
      alpha_diagnostic: alpha,
    };
  }

  const extras = {};
  for (const [k, r] of Object.entries(cfg.extras || {})) {
    extras[k] = { recipe: r.paint, ...resolveOpaque(readings, `extra-${k}`) };
  }
  return { rows, grounds, extras };
}

function ratiosFor(sideName, side, cfg) {
  const out = [];
  const hexOf = (key) => {
    if (key.includes("@")) {
      const [row, g] = key.split("@");
      return side.rows[row]?.over?.[g]?.hex;
    }
    return side.rows[key]?.hex ?? side.extras?.[key]?.hex ?? side.grounds[key]?.hex;
  };
  const push = (fg, bgk, kind) => {
    const a = hexOf(fg);
    const b = hexOf(bgk);
    if (a && b) out.push({ side: sideName, fg, bg: bgk, kind, fg_hex: a, bg_hex: b, painted: ratio(a, b) });
    else out.push({ side: sideName, fg, bg: bgk, kind, painted: null, reason: "an operand is unresolved" });
  };
  for (const t of TEXT_ROWS) for (const g of cfg.textGrounds) push(t, g, "text");
  for (const g of cfg.textGrounds) if (cfg.extras?.["warning-fallback"]) push("warning-fallback", g, "text");
  for (const [a, b] of cfg.extraPairs || []) push(a, b, "pair");
  for (const t of ["muted", "faint"]) for (const g of cfg.translucentOver) push(`${t}@${g}`, g, "text");
  for (const [a, b] of SEPARATIONS) push(a, b, "separation");
  return out;
}

// ── provenance ───────────────────────────────────────────────────────────

function darkBlockDeclarations() {
  const css = readFileSync(join(APP_ROOT, "assets/css/app.css"), "utf8");
  const start = css.search(/^\s*name:\s*"dark";/m);
  if (start < 0) die('no name: "dark" block in app.css');
  const end = css.indexOf("\n}", start);
  const block = css.slice(start, end);
  const out = {};
  for (const m of block.matchAll(/^\s*(--[a-z0-9-]+)\s*:\s*([^;]+);/gm)) out[m[1]] = `${m[1]}: ${m[2].trim()};`;
  return out;
}

function mockDeclarations(html) {
  const root = html.match(/:root\s*\{([^}]*)\}/);
  const out = {};
  if (root) for (const m of root[1].matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) out[m[1]] = `${m[1]}: ${m[2].trim()};`;
  return out;
}

function recipeCounts() {
  const counts = {};
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const p = join(dir, name);
      if (statSync(p).isDirectory()) walk(p);
      else if (/\.(ex|heex)$/.test(name)) {
        for (const m of readFileSync(p, "utf8").matchAll(/text-base-content\/(\d+)/g)) {
          counts[m[1]] = (counts[m[1]] || 0) + 1;
        }
      }
    }
  };
  walk(join(APP_ROOT, "lib"));
  return Object.fromEntries(Object.entries(counts).sort((a, b) => b[1] - a[1]));
}

function gitHead() {
  try {
    const sha = execFileSync(GIT, ["-C", REPO_ROOT, "rev-parse", "HEAD"]).toString().trim();
    const dirty = execFileSync(GIT, ["-C", REPO_ROOT, "status", "--porcelain", "--", "apps/platform/assets"])
      .toString()
      .trim();
    return { sha, assets_dirty: dirty.length > 0 };
  } catch (e) {
    return { sha: null, error: String(e).slice(0, 200) };
  }
}

// ── main ─────────────────────────────────────────────────────────────────

const page = await isolatedPage(W, H);
try {
  // Live: a real app page from the dev server, forced dark.
  await page.navigate(`${LIVE_URL}/dev/login?as=${encodeURIComponent(LIVE_USER)}`);
  const landed = await page.evaluate("({path: location.pathname, title: document.title, sheets: document.styleSheets.length})");
  if (!landed.path.startsWith("/chat")) die(`live login did not land in the app: ${JSON.stringify(landed)}`);
  await page.evaluate(`document.documentElement.setAttribute("data-theme", "dark"); true`);
  const theme = await page.evaluate(`document.documentElement.getAttribute("data-theme")`);
  if (theme !== "dark") die(`data-theme is ${theme}, not dark`);

  const liveControls = await runControls(page, "live");
  const live = await readSide(page, LIVE);
  const liveTheme = await page.evaluate(`document.documentElement.getAttribute("data-theme")`);
  if (liveTheme !== "dark") die("data-theme changed during the live read");

  // Mock: loaded from outside the repo.
  await page.navigate(pathToFileURL(MOCK_HTML).href);
  const mockControls = await runControls(page, "mock");
  const mock = await readSide(page, MOCK);

  const decls = darkBlockDeclarations();
  for (const [k, r] of Object.entries(LIVE.rows)) live.rows[k].declaration = decls[r.decl] ?? null;
  for (const [k, r] of Object.entries(LIVE.extras)) live.extras[k].declaration = decls[r.decl] ?? null;
  const mockDecls = mockDeclarations(readFileSync(MOCK_HTML, "utf8"));
  for (const [k, r] of Object.entries(MOCK.rows)) mock.rows[k].declaration = mockDecls[r.decl] ?? null;

  const counts = recipeCounts();
  const results = {
    task: "01a0cf85-5bee-7001-844f-bcf4761591ae",
    measured_on: new Date().toISOString().slice(0, 10),
    browser: page.version,
    viewport: `${W}x${H} @1x`,
    git: gitHead(),
    live_page: { path: landed.path, data_theme: liveTheme },
    mock_file: { basename: MOCK_HTML.split("/").pop(), bytes: statSync(MOCK_HTML).size },
    convention:
      "Every hex is a painted byte read from a screenshot. Every `painted` ratio is hex-to-hex " +
      "(WcagContrast.contrast_painted/2). Token-space ratios live in the ExUnit fixture.",
    muted_recipe_counts_in_lib: counts,
    muted_recipe_rule:
      "muted = the most-used text-base-content/NN in lib/; faint = the most-used at or below 40%",
    controls: { live: liveControls, mock: mockControls },
    live,
    mock,
    ratios: [...ratiosFor("live", live, LIVE), ...ratiosFor("mock", mock, MOCK)],
  };
  writeFileSync(OUT, JSON.stringify(results, null, 2) + "\n");
  console.log(`wrote ${OUT}`);
} finally {
  await page.close();
}
