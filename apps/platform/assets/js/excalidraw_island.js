// Excalidraw island entry point — a SEPARATE esbuild entry point, never part
// of js/app.js.
//
// This file must NOT be imported by js/app.js or js/hooks/index.js, and must
// NOT import anything from js/hooks/. Excalidraw plus React is ~4.7 MB
// minified, against ~700 KB for the whole application bundle; a single import
// edge from app.js would put all of it on every page load. The build guard at
// test/no_excalidraw_in_app_bundle_test.mjs enforces that.
//
// It is built by the `excalidraw` esbuild profile in config/config.exs into
// priv/static/assets/js/excalidraw_island.js, and fetched on demand by
// js/lib/load_excalidraw.js, which resolves with `window.__suite_excalidraw`.

import "./excalidraw_asset_path.js";

import React from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, exportToBlob } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

// One frozen object is the island's whole public surface. Consumers get the
// React pieces they need to mount a board plus the export helper; nothing
// else about the package leaks into global scope.
const api = Object.freeze({
  React,
  createRoot,
  Excalidraw,
  exportToBlob,
  // The prop name Excalidraw uses to hand back its imperative editor API
  // (`updateScene` and friends). It lives HERE, as a string in the island,
  // rather than being written literally in the hook, because that literal
  // would put the token "excalidraw" into js/app.js and fire the build guard
  // in test/no_excalidraw_in_app_bundle_test.mjs. The right fix is for the
  // island to own Excalidraw's vocabulary — which is what this object is for
  // — not to widen the guard's exemption list. Widening it to cover an
  // identifier the app bundle genuinely contains would make the guard weaker
  // for every future edge, and the guard is the only thing standing between
  // every page load and 4.9 MB.
  editorApiProp: "excalidrawAPI",
  // The `.excalidraw` scene-file vocabulary (task 019fcfcf stage 5). Same
  // reasoning as `editorApiProp`: writing `type: "excalidraw"` or a
  // `"board.excalidraw"` filename literally in the hook would put the token
  // into js/app.js and fire the build guard. The island owns the vocabulary.
  sceneFileType: "excalidraw",
  sceneFileVersion: 2,
  sceneFileExtension: ".excalidraw",
  version: "0.18.1",
});

if (typeof window !== "undefined") {
  window.__suite_excalidraw = api;
}

export default api;
