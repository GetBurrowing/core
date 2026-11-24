// Build guard: the Voice tab's on-device half must NEVER enter js/app.js
// (task 01a20dc5 stage 3).
//
// It is its own esbuild entry point (the `voice_native` profile in
// config/config.exs), fetched by js/hooks/voice_tab.js only inside the iOS app
// with the BurrowVoice plugin present. The un-split `platform` profile INLINES a
// dynamic import(), so a stray import edge would put it in the bundle every page
// loads while still looking lazy in the source. This builds js/app.js exactly as
// the `platform` profile does and asserts on the bytes. The KB ceiling itself is
// guarded by no_excalidraw_in_app_bundle_test.mjs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const ASSETS = resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
const DEPS = resolve(ASSETS, "..", "deps");
const EXTRA = (process.env.NODE_PATH || "").split(":").filter(Boolean);

async function bundle(entry, extra = {}) {
  const result = await build({
    absWorkingDir: ASSETS,
    entryPoints: [entry],
    bundle: true,
    minify: true,
    target: "es2022",
    write: false,
    outdir: "out",
    nodePaths: [DEPS, ...EXTRA],
    ...extra,
  });
  return Buffer.from(result.outputFiles.find((f) => f.path.endsWith(".js")).contents).toString("utf8");
}

const buildApp = () =>
  bundle("js/app.js", {
    // app.js imports the colocated hooks from "phoenix-colocated/platform",
    // which `mix compile` writes into the build path. CI runs these guards
    // before compiling, so it stays external here.
    external: ["/fonts/*", "/images/*", "phoenix-colocated/*"],
    alias: { "@": ".", "@extensions": "./js/extensions/none.js" },
  });

// Strings only the on-device half ships: the events it pushes, the copy it
// draws and the capability seam's own vocabulary.
const ISLAND_ONLY = [
  "voice_native_turn",
  "voice_native_speaking",
  "No words heard",
  "Not sent",
  "assets_missing",
  "stopSpeaking",
];

test("js/app.js contains none of the voice_native island", async () => {
  const app = await buildApp();
  for (const needle of ISLAND_ONLY) {
    assert.ok(!app.includes(needle), `js/app.js contains ${JSON.stringify(needle)}: the on-device Voice half leaked into the main bundle`);
  }
  // Positive control: the loader is there, so absence above is a measurement.
  assert.ok(app.includes("/assets/js/voice_native_island.js"), "the voice_native loader is missing from app.js");
  assert.ok(app.includes("__burrowVoiceNative"), "the voice_native loader's global is missing from app.js");
});

test("the voice_native island does build, and it is where the on-device half lives", async () => {
  const island = await bundle("js/voice_native_island.js");
  for (const needle of ISLAND_ONLY) {
    assert.ok(island.includes(needle), `the island does not contain ${JSON.stringify(needle)}`);
  }
  assert.ok(island.includes("__burrowVoiceNative"));
  assert.ok(!island.includes("livekit"), "the island must not carry LiveKit");
});
