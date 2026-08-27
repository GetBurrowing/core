// Build guard: Excalidraw must NEVER enter js/app.js.
//
// Excalidraw + React is ~4.7 MB minified against ~700 KB for the entire
// application bundle. The whole point of building it as a separate esbuild
// entry point (the `excalidraw` profile in config/config.exs) is that no page
// pays for it until the whiteboard is opened. A single stray import edge —
// including an `await import(...)`, which the un-split `platform` esbuild
// profile INLINES into the one output file — would undo that while still
// looking lazy in the source.
//
// So this builds js/app.js exactly as the `platform` profile does and asserts
// on the bytes, not on the import graph as written.
//
// This guard was verified to FAIL under a mutation: adding a top-level
// `import "@excalidraw/excalidraw"` to js/app.js made both assertions fire
// (bundle grew to ~8.2 MB and contained "excalidraw"). A guard that has only
// ever passed proves nothing.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const ASSETS = resolve(HERE, "..");

// Mirrors `config :esbuild, platform: [args: ...]` in config/config.exs.
// Keep in sync — if the profile changes, this guard must build the same thing
// the profile does or it is measuring a bundle nobody ships.
const MAX_BYTES = 800 * 1024;

// The profile also sets `env: %{"NODE_PATH" => [.../deps, build_path]}`, and
// that half was missing here until this commit. js/app.js has exactly three
// bare imports — "phoenix_html", "phoenix", "phoenix_live_view" — and all three
// are Elixir deps whose JS lives in apps/platform/deps, NOT in
// assets/node_modules. Without this the build threw `Could not resolve
// "phoenix"` and BOTH assertions below failed for a reason that had nothing to
// do with the bundle. esbuild's JS API does not read the NODE_PATH environment
// variable (only its CLI does), so the paths are passed explicitly.
//
// Consequence: this file needs `mix deps.get` to have run. That is why CI runs
// the JS suites inside the job that already fetched deps — see
// .github/workflows/ci.yml, "Run JS asset test suites".
const DEPS = resolve(ASSETS, "..", "deps");

async function buildAppBundle() {
  const result = await build({
    absWorkingDir: ASSETS,
    entryPoints: ["js/app.js"],
    bundle: true,
    minify: true,
    target: "es2022",
    write: false,
    outdir: "out",
    external: ["/fonts/*", "/images/*"],
    alias: { "@": "." },
    nodePaths: [DEPS],
  });

  const js = result.outputFiles.find((f) => f.path.endsWith(".js"));
  assert.ok(js, "esbuild produced no .js output for js/app.js");
  return js;
}

// The loader itself (js/lib/load_excalidraw.js) DOES ship in app.js — that is
// the point: it is the ~1 KB of code that fetches the island on demand. It
// necessarily names the island: the script URL it injects, the stylesheet URL,
// and the `window.__suite_excalidraw` global it resolves with all survive
// minification as string/property literals. Those three tokens are the loader's
// entire vocabulary, so we strip exactly them and then apply the original,
// unweakened check to everything that is left. Anything else spelling
// "excalidraw" in the bundle means the library itself got in.
//
// Added task 019fcfcf stage 3, when registering the MeetingWhiteboard hook put
// the loader on app.js's import graph for the first time. Verified this
// narrowing does NOT defang the guard: with a top-level
// `import "@excalidraw/excalidraw"` in js/app.js the test still fails on
// hundreds of surviving occurrences (and the 800 KB ceiling below fires too).
const LOADER_TOKENS = [
  "/assets/js/excalidraw_island.js",
  "/assets/js/excalidraw_island.css",
  "__suite_excalidraw",
  // `api.Excalidraw` — the MeetingWhiteboard hook reading the component off
  // the island's frozen API object. A property READ survives minification;
  // the component it reads is still only inside the island bundle.
  ".excalidraw",
];

test("js/app.js bundle does not contain excalidraw", async () => {
  const js = await buildAppBundle();
  const raw = Buffer.from(js.contents).toString("utf8").toLowerCase();
  const text = LOADER_TOKENS.reduce(
    (acc, token) => acc.split(token.toLowerCase()).join(""),
    raw
  );

  assert.ok(
    !text.includes("excalidraw"),
    "js/app.js bundle contains the string 'excalidraw'. Excalidraw must stay in " +
      "the separate island entry point (js/excalidraw_island.js), loaded on " +
      "demand via js/lib/load_excalidraw.js. Check for a new import edge from " +
      "js/app.js or js/hooks/index.js — including a dynamic import(), which " +
      "the un-split `platform` esbuild profile inlines into app.js."
  );
});

test("js/app.js bundle stays under 800 KB minified", async () => {
  const js = await buildAppBundle();
  const bytes = js.contents.byteLength;

  assert.ok(
    bytes < MAX_BYTES,
    `js/app.js bundle is ${bytes} bytes (${(bytes / 1024).toFixed(1)} KB), over the ` +
      `${MAX_BYTES} byte (800 KB) ceiling. Either something large was added to the ` +
      "application bundle, or a lazily-loaded island leaked into it."
  );
});
