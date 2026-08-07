// Idempotent loader for the Excalidraw island.
//
// Shape mirrors `ensureMermaid()` in js/hooks/mermaid_diagram.js: cache the
// promise, not the result, so concurrent callers share one in-flight fetch and
// exactly one <script> is ever injected.
//
// Deliberate divergence from that precedent: mermaid_diagram.js loads from
// jsdelivr, and we do NOT copy that here. The island is served from OUR OWN
// origin so the MIT-licensed bytes and the accompanying licence notice
// (excalidraw_island.js.LEGAL.txt, emitted by --legal-comments=linked) stay
// under our control, and so the whiteboard makes zero third-party requests.

export const ISLAND_SRC = "/assets/js/excalidraw_island.js";
export const ISLAND_CSS = "/assets/js/excalidraw_island.css";

let islandReady = null;

/**
 * Resolves with `window.__suite_excalidraw`. Safe to call concurrently and
 * repeatedly: the first call injects the <script> (and its stylesheet), every
 * later call returns the same promise.
 *
 * Rejects if the script fails to load, or if it loads without publishing the
 * global — a silent `undefined` would surface later as an unrelated crash in
 * the caller.
 */
export function loadExcalidraw() {
  if (islandReady) return islandReady;

  islandReady = new Promise((resolve, reject) => {
    if (window.__suite_excalidraw) {
      resolve(window.__suite_excalidraw);
      return;
    }

    if (!document.querySelector(`link[href="${ISLAND_CSS}"]`)) {
      const link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = ISLAND_CSS;
      document.head.appendChild(link);
    }

    const script = document.createElement("script");
    script.src = ISLAND_SRC;
    script.async = true;
    script.onload = () => {
      if (window.__suite_excalidraw) {
        resolve(window.__suite_excalidraw);
      } else {
        reject(
          new Error(
            `${ISLAND_SRC} loaded but did not define window.__suite_excalidraw`
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
export function __resetExcalidrawLoaderForTest() {
  islandReady = null;
}

export default loadExcalidraw;
