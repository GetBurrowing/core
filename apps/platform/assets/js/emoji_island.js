// Emoji inventory island entry point — a SEPARATE esbuild entry point, never
// part of js/app.js.
//
// This file must NOT be imported by js/app.js or js/hooks/index.js. The
// inventory is ~1,850 emoji with their CLDR search keywords; app.js loads on
// every page in the product, including /tasks and /inbox, and none of those
// pages can open a reaction picker. The build guard in
// test/no_emoji_data_in_app_bundle_test.mjs enforces that.
//
// Nor is `await import("../emoji/data.js")` from a hook an alternative: the
// `platform` esbuild profile runs --bundle WITHOUT --splitting and without
// --format=esm, and in that configuration esbuild INLINES a dynamic import()
// into the single output file. It would ship the whole dataset on every page
// while reading as lazy in the source. Same reasoning as the Excalidraw
// island — see config/config.exs.
//
// It is built by the `emoji` esbuild profile in config/config.exs into
// priv/static/assets/js/emoji_island.js, and fetched on demand by
// js/lib/load_emoji.js, which resolves with `window.__suite_emoji`.
//
// This file is thin BY DESIGN and must stay that way: it lives under assets/js,
// which app.css scans via `@source "../js"`. The data it re-exports lives in
// assets/emoji/data.js, outside that glob, because CLDR emoji keywords include
// "block", "flex", "grid" and "table" and Tailwind would mine utility classes
// out of them.

import { EMOJI, CATEGORIES } from "../emoji/data.js";

// One frozen object is the island's whole public surface, mirroring
// js/excalidraw_island.js. Consumers read the inventory; nothing mutates it.
const api = Object.freeze({
  EMOJI,
  CATEGORIES,
});

window.__suite_emoji = api;

export default api;
