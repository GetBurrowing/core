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
//
// Raised from 800 KB to 896 KB by task 01a0dbd6 stage 4 (multiplayer
// game_stream canvas), measured with this file's own build: app.js was
// 810,955 bytes at e1956158 and 825,043 with the roster strip, per-pad slots
// and the input router (the game_stream hook family went from 20,992 to
// 35,069 bytes bundled). The ceiling exists to catch an island leaking in
// (Excalidraw put app.js at ~8.2 MB under the recorded mutation), which 896 KB
// still does by a factor of nine; 14 KB of first-party hook code is not that.
// The structural alternative, if app.js keeps growing, is to load the
// game_stream hook (flag-gated, GAME_STREAM_ENABLED) as an island like
// emoji_island.js.
//
// Raised from 896 KB to 960 KB by task 01a166be (redesign press feedback):
// the WITH-Play app.js measured 919,154 bytes in CI run 39929391456, 1,650
// over 896 KB, after nav_pending.js and top_bar.js (optimistic tab swap,
// pending pulse, rollback toast) landed as first-party code. Task 01a1557a-997a
// (Burrow redesign 10: composer chip field and in-flow @mention list) made the
// same raise independently: with-Play app.js measured 929,835 bytes against
// feat/redesign f61f50e31's 914,453 (+15,382: the contenteditable
// compose_input hook and lib/mention_field.js). Both are first-party hook code.
// Same reasoning as above: 960 KB still catches an island leak (~8.2 MB) by a
// factor of eight.
//
// Task 01a13ca2 (Burrow iOS hybrid video, companion connection) raised the
// ceiling on main from 896 KB to 912 KB, measured in CI with the with-Play
// build: main was 909,510 bytes at d6577958 and the task branch was 919,160
// bytes. That is first-party meeting hook code (the companion Room,
// per-person grouping, and the sharer label and its share-end teardown), not
// an island. When main was merged into feat/redesign the higher 960 KB
// ceiling was kept; it covers both sides' first-party growth.
const MAX_BYTES = 960 * 1024;

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

// Both build flavours (ADR 0055, task 01a0ee08 stage 3). The `platform`
// profile aliases `@extensions` to js/extensions/none.js, the empty hook
// registry of the WITHOUT-modules build. A with-modules release host aliases
// it to the entry `mix platform.extensions.assets` generates; set
// BURROW_EXTENSIONS_JS to that file to run every assertion below against the
// WITH-modules bundle, and BURROW_EXTENSION_LITERAL to a string the module's
// hook is known to ship (the positive control for the absence check below).
// The old names SUITE_EXTENSIONS_JS and SUITE_EXTENSION_LITERAL are still read
// as fallbacks. Unset, this is the without-modules build and nothing else
// changes.
// Burrow rename (task 01a14b9e): BURROW_<NAME> first, SUITE_<NAME> fallback, "" counts
// as unset, one stderr line per name per process on fallback. Both full
// literals are named at the call site so the stage-5 text guard sees them.
const warnedDeprecated = new Set();
function compatEnv(burrow, suite) {
  const value = process.env[burrow];
  if (value) return value;
  const old = process.env[suite];
  if (old) {
    if (!warnedDeprecated.has(suite)) {
      warnedDeprecated.add(suite);
      process.stderr.write(`deprecated: ${suite} is set; rename it to ${burrow}\n`);
    }
    return old;
  }
  return undefined;
}
const EXTENSIONS_ENV = compatEnv("BURROW_EXTENSIONS_JS", "SUITE_EXTENSIONS_JS");
const EXTENSIONS_JS = EXTENSIONS_ENV ? resolve(EXTENSIONS_ENV) : null;

// A string literal only Play's hook ships: the LiveView event its viewer
// pushes to attach (apps/game_stream/assets/js/hooks/game_stream.js). It must
// be absent from the without-modules bundle; BURROW_EXTENSION_LITERAL
// (fallback SUITE_EXTENSION_LITERAL) overrides it for another module.
const EXTENSION_LITERAL =
  compatEnv("BURROW_EXTENSION_LITERAL", "SUITE_EXTENSION_LITERAL") || "game_stream_attach";

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
    alias: { "@": ".", "@extensions": EXTENSIONS_JS || "./js/extensions/none.js" },
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
// hundreds of surviving occurrences (and the KB ceiling below fires too).
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

test(`js/app.js bundle stays under ${MAX_BYTES / 1024} KB minified`, async (t) => {
  const js = await buildAppBundle();
  const bytes = js.contents.byteLength;
  const flavour = EXTENSIONS_JS ? `with modules (${EXTENSIONS_JS})` : "without modules";
  t.diagnostic(`app.js ${flavour}: ${bytes} bytes`);
  console.log(`[bundle-cap] app.js ${flavour}: ${bytes} bytes`);

  assert.ok(
    bytes < MAX_BYTES,
    `js/app.js bundle is ${bytes} bytes (${(bytes / 1024).toFixed(1)} KB), over the ` +
      `${MAX_BYTES} byte (${MAX_BYTES / 1024} KB) ceiling. Either something large was added to the ` +
      "application bundle, or a lazily-loaded island leaked into it."
  );
});

test("a module's hook is in app.js only when the build includes the module", async () => {
  const js = await buildAppBundle();
  const text = Buffer.from(js.contents).toString("utf8");

  if (EXTENSIONS_JS) {
    // Positive control: the literal survives minification, so its absence
    // below is a measurement and not a blind spot.
    assert.ok(
      text.includes(EXTENSION_LITERAL),
      `with-modules app.js lacks ${JSON.stringify(EXTENSION_LITERAL)}; the ` +
        "generated @extensions entry did not bring the module's hook in"
    );
  } else {
    assert.ok(
      !text.includes(EXTENSION_LITERAL),
      `without-modules app.js contains ${JSON.stringify(EXTENSION_LITERAL)}: a ` +
        "module's hook reached core's bundle. js/hooks/index.js must reach " +
        "module hooks only through the @extensions alias."
    );
  }
});
