// Build guard: xterm must NEVER enter js/app.js (task 01a17b17 stage 3).
//
// The remote terminal is its own esbuild entry point (the `terminal` profile in
// config/config.exs), loaded on demand by js/lib/load_terminal.js. The un-split
// `platform` profile INLINES a dynamic import(), so a stray import edge would put
// xterm in the bundle every page loads while still looking lazy in the source.
// This builds js/app.js exactly as the `platform` profile does and asserts on
// the bytes. The 992 KB ceiling itself is guarded by no_excalidraw_in_app_bundle_test.mjs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const ASSETS = resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
const DEPS = resolve(ASSETS, "..", "deps");
const EXTRA = (process.env.NODE_PATH || "").split(":").filter(Boolean);

async function buildApp() {
  const result = await build({
    absWorkingDir: ASSETS,
    entryPoints: ["js/app.js"],
    bundle: true,
    minify: true,
    target: "es2022",
    write: false,
    outdir: "out",
    external: ["/fonts/*", "/images/*"],
    alias: { "@": ".", "@extensions": "./js/extensions/none.js" },
    nodePaths: [DEPS, ...EXTRA],
  });
  return Buffer.from(result.outputFiles.find((f) => f.path.endsWith(".js")).contents).toString("utf8");
}

// The loader and the thin hook DO ship in app.js: they name the island's URLs
// and its global, and nothing else. Strip exactly those, then look for the library.
const LOADER_TOKENS = ["/assets/js/terminal_island.js", "/assets/js/terminal_island.css", "__burrow_terminal"];

test("js/app.js contains no xterm code", async () => {
  const raw = await buildApp();
  const text = LOADER_TOKENS.reduce((acc, t) => acc.split(t).join(""), raw);
  for (const needle of ["xterm", "@xterm", "FitAddon", "terminal_island"]) {
    assert.ok(!text.includes(needle), `js/app.js contains ${JSON.stringify(needle)}: xterm leaked into the main bundle`);
  }
  // Positive control: the loader is there, so absence above is a measurement.
  assert.ok(raw.includes("__burrow_terminal"), "the TerminalHost loader is missing from app.js");
});

test("the terminal island does build, and it is where xterm lives", async () => {
  const result = await build({
    absWorkingDir: ASSETS,
    entryPoints: ["js/terminal_island.js"],
    bundle: true,
    minify: true,
    target: "es2022",
    write: false,
    outdir: "out",
    nodePaths: [DEPS, ...EXTRA],
  });
  const js = Buffer.from(result.outputFiles.find((f) => f.path.endsWith(".js")).contents).toString("utf8");
  assert.ok(js.includes("xterm"), "the island bundle does not contain xterm");
  assert.ok(js.includes("__burrow_terminal"));
});
