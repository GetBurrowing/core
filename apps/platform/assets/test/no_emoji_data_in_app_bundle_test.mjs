// Build guard: the emoji inventory must NEVER enter js/app.js.
//
// Sibling of no_excalidraw_in_app_bundle_test.mjs, and the reasoning is the
// same shape at a smaller scale. The inventory is ~1,850 emoji with their CLDR
// search keywords — 155 KB minified against a ~700 KB application bundle — and
// app.js loads on EVERY page in the product, including /tasks and /inbox, none
// of which can open a reaction picker.
//
// The trap this exists for is specific: the `platform` esbuild profile runs
// --bundle WITHOUT --splitting and without --format=esm, and in that
// configuration esbuild INLINES a dynamic import() into the single output file.
// So `await import("../emoji/data.js")` from a hook would ship the whole
// dataset on every page while reading as lazy in the source, and no amount of
// looking at the import graph would show it. This asserts on the built bytes.
//
// Verified to FAIL under mutation: adding `import "../emoji/data.js"` to
// js/app.js fires it, and so does replacing js/emoji_island.js's static import
// with `await import(...)` called from app.js.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const ASSETS = resolve(HERE, "..");

// js/app.js's three bare imports ("phoenix", "phoenix_html",
// "phoenix_live_view") are Elixir deps whose JavaScript lives in
// apps/platform/deps, not in assets/node_modules, and esbuild's JS API does not
// read NODE_PATH. Same as the excalidraw guard — see its header for why this
// means the JS suites run in the CI job that has already fetched deps.
const DEPS = resolve(ASSETS, "..", "deps");

// The `@extensions` alias the `platform` profile sets (ADR 0055): the empty
// registry by default, or a with-modules host's generated entry when
// BURROW_EXTENSIONS_JS names one (see no_excalidraw_in_app_bundle_test.mjs).
const EXTENSIONS_ENV = process.env.BURROW_EXTENSIONS_JS;
const EXTENSIONS = EXTENSIONS_ENV ? resolve(EXTENSIONS_ENV) : "./js/extensions/none.js";

// CLDR short names that exist in the dataset and nowhere else a human would
// plausibly type. Checking for names rather than for glyphs on purpose: a
// single emoji character can legitimately appear in application code (a label,
// a placeholder, a comment), so a glyph search would produce false failures
// that get "fixed" by weakening the guard.
//
// ASCII ONLY, and that is load-bearing. "flag: st. barthélemy" was in this list
// until the island-side check below rejected it: esbuild's minifier escapes
// non-ASCII to \xE9, so the accented name never appears literally in either
// bundle. As a marker it would have been a permanent false negative — silently
// unable to detect the leak it was added to detect. The island check is what
// caught it.
const DATASET_MARKERS = [
  "chart increasing with yen",
  "woman with headscarf",
  "kaaba",
  "desert island",
];

// The loader (js/lib/load_emoji.js) DOES ship in app.js — that is its whole
// job, ~1 KB of code that fetches the island on demand. It necessarily names
// the island: the script URL it injects and the global it resolves with both
// survive minification as literals. Those are its entire vocabulary, so they
// are stripped before the check rather than the check being loosened.
const LOADER_TOKENS = ["/assets/js/emoji_island.js", "__suite_emoji"];

test("js/app.js bundle does not contain the emoji inventory", async () => {
  const result = await build({
    absWorkingDir: ASSETS,
    entryPoints: ["js/app.js"],
    bundle: true,
    minify: true,
    target: "es2022",
    write: false,
    outdir: "out",
    external: ["/fonts/*", "/images/*"],
    alias: { "@": ".", "@extensions": EXTENSIONS },
    nodePaths: [DEPS],
  });

  const js = result.outputFiles.find((f) => f.path.endsWith(".js"));
  assert.ok(js, "esbuild produced no .js output for js/app.js");

  const raw = Buffer.from(js.contents).toString("utf8").toLowerCase();
  const text = LOADER_TOKENS.reduce(
    (acc, token) => acc.split(token.toLowerCase()).join(""),
    raw
  );

  for (const marker of DATASET_MARKERS) {
    assert.ok(
      !text.includes(marker),
      `js/app.js bundle contains ${JSON.stringify(marker)}, so assets/emoji/data.js ` +
        `got into the application bundle. It must stay in the separate island entry ` +
        `point (js/emoji_island.js), loaded on demand via js/lib/load_emoji.js. Look ` +
        `for a new import edge from js/app.js or js/hooks/index.js — including a ` +
        `dynamic import(), which the un-split \`platform\` esbuild profile inlines.`
    );
  }
});

test("the emoji island builds, and is the thing carrying the weight", async () => {
  // The other half of the guard above: proving the dataset is absent from
  // app.js is worth nothing if it turns out to be absent from the island too
  // (a broken import path, a renamed export). This is the instrument check.
  const result = await build({
    absWorkingDir: ASSETS,
    entryPoints: ["js/emoji_island.js"],
    bundle: true,
    minify: true,
    target: "es2022",
    write: false,
    outdir: "out",
  });

  const js = result.outputFiles.find((f) => f.path.endsWith(".js"));
  assert.ok(js, "esbuild produced no .js output for js/emoji_island.js");

  const text = Buffer.from(js.contents).toString("utf8").toLowerCase();
  for (const marker of DATASET_MARKERS) {
    assert.ok(text.includes(marker), `the island bundle is missing ${JSON.stringify(marker)}`);
  }

  // A ceiling, not a target. 250 KB is the budget this dataset was designed
  // against; the build measured 155 KB, so this fires only on a change that
  // adds ~60% — re-including skin-tone forms, or dropping the short {e,n,k,c}
  // key names for verbose ones.
  const bytes = js.contents.byteLength;
  assert.ok(
    bytes < 250 * 1024,
    `emoji island is ${(bytes / 1024).toFixed(1)} KB minified, over the 250 KB budget. ` +
      `Trim keyword lists (cap per entry, drop keywords that are substrings of the ` +
      `short name) before dropping emoji.`
  );
});
