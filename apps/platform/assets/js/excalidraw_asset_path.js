// Self-hosted asset path for `@excalidraw/excalidraw`.
//
// The package defaults `window.EXCALIDRAW_ASSET_PATH` to a public CDN for its
// fonts and worker assets. Burrow self-hosts them instead: the MIT-licensed
// bytes and the licence notice stay under our control, and the whiteboard
// makes zero third-party requests.
//
// This lives in its own module, imported FIRST by excalidraw_island.js, so the
// assignment is evaluated before the package module body runs (ES module
// imports are evaluated in source order, and an assignment placed in the
// island body would run AFTER the package had already initialised).
//
// The build copies node_modules/@excalidraw/excalidraw/dist/prod/{fonts,data}
// into priv/static/assets/excalidraw/ — see assets/scripts/copy_excalidraw_assets.mjs.

if (typeof window !== "undefined") {
  window.EXCALIDRAW_ASSET_PATH = "/assets/excalidraw/";
}

export const EXCALIDRAW_ASSET_PATH = "/assets/excalidraw/";
