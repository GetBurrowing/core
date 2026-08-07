#!/usr/bin/env node
// Copy Excalidraw's runtime font/data assets into priv/static so they are
// served from OUR OWN origin.
//
// `@excalidraw/excalidraw` otherwise resolves fonts and worker data against a
// public CDN. js/excalidraw_asset_path.js pins
// `window.EXCALIDRAW_ASSET_PATH = "/assets/excalidraw/"`, and this script is
// what puts bytes behind that path. Run from `mix assets.build` /
// `assets.deploy` (see mix.exs aliases) before phx.digest.
//
// Idempotent: it mirrors the directory each time, overwriting.

import { cp, mkdir, rm, access } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ASSETS = resolve(HERE, "..");
const SRC = resolve(ASSETS, "node_modules/@excalidraw/excalidraw/dist/prod");
const DEST = resolve(ASSETS, "../priv/static/assets/excalidraw");

// Only the subdirectories the browser fetches at runtime. The JS chunks are
// bundled by esbuild into excalidraw_island.js and must not be duplicated here.
const SUBDIRS = ["fonts", "data"];

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

if (!(await exists(SRC))) {
  console.error(
    `copy_excalidraw_assets: ${SRC} not found. Run \`npm install\` in assets/ first.`
  );
  process.exit(1);
}

await rm(DEST, { recursive: true, force: true });
await mkdir(DEST, { recursive: true });

let copied = 0;
for (const sub of SUBDIRS) {
  const from = resolve(SRC, sub);
  if (!(await exists(from))) continue;
  await cp(from, resolve(DEST, sub), { recursive: true });
  copied += 1;
}

if (copied === 0) {
  console.error(
    `copy_excalidraw_assets: none of ${SUBDIRS.join(", ")} exist under ${SRC}. ` +
      "The package layout changed; update this script rather than shipping a whiteboard with no fonts."
  );
  process.exit(1);
}

console.log(`copy_excalidraw_assets: copied ${copied} directories into priv/static/assets/excalidraw`);
