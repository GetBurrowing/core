// Idempotent loader for the emoji inventory island.
//
// Shape mirrors js/lib/load_excalidraw.js: cache the promise, not the result,
// so concurrent callers share one in-flight fetch and exactly one <script> is
// ever injected. Simpler than that one in a single respect — the emoji island
// has no stylesheet, so there is no <link> to inject.
//
// The island is served from OUR OWN origin. PlatformWeb.static_paths/0
// (platform_web.ex) allowlists "assets", and sw.js's STATIC_EXT includes ".js",
// so the bundle is digested and service-worker cached like any other asset.
// That is also why the inventory is emitted as .js and not .json: neither the
// static allowlist nor STATIC_EXT covers .json.

export const ISLAND_SRC = "/assets/js/emoji_island.js";

let islandReady = null;

/**
 * Resolves with `window.__suite_emoji` — `{ EMOJI, CATEGORIES }`. Safe to call
 * concurrently and repeatedly: the first call injects the <script>, every later
 * call returns the same promise.
 *
 * Rejects if the script fails to load, or if it loads without publishing the
 * global — a silent `undefined` would surface later as an unrelated crash in
 * the caller.
 */
export function loadEmoji() {
  if (islandReady) return islandReady;

  islandReady = new Promise((resolve, reject) => {
    if (window.__suite_emoji) {
      resolve(window.__suite_emoji);
      return;
    }

    const script = document.createElement("script");
    script.src = ISLAND_SRC;
    script.async = true;
    script.onload = () => {
      if (window.__suite_emoji) {
        resolve(window.__suite_emoji);
      } else {
        reject(
          new Error(
            `${ISLAND_SRC} loaded but did not define window.__suite_emoji`
          )
        );
      }
    };
    script.onerror = () => reject(new Error(`Failed to load ${ISLAND_SRC}`));
    document.head.appendChild(script);
  });

  // A failed load must not poison the cache forever — drop it so a later
  // attempt (e.g. after the user regains connectivity) can retry.
  islandReady.catch(() => {
    islandReady = null;
  });

  return islandReady;
}

/** Test seam: forget any cached load. Not used by application code. */
export function __resetEmojiLoaderForTest() {
  islandReady = null;
}

export default loadEmoji;
