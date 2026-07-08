#!/usr/bin/env node
// check_no_direct_localstorage.mjs — task 019f3e9a stage 4.
//
// Walks the JS source tree and rejects any `localStorage.*` call that isn't
// going through `Suite.ClientState`. This is the compile-time contract that
// keeps the client-state store honest: new code has exactly one way to
// persist per-tab preferences, and it's the ClientState wrapper (which
// centralises quota/security-error handling and the `suite:<ns>:<key>`
// naming scheme).
//
// The check is deliberately regex-only — no AST — because the target
// pattern is trivially recognisable and we want the script to run inside
// `npm test` with zero dependencies beyond the Node standard library.
//
// Allowlist mechanics:
//   1. Files enumerated in `ALLOWLISTED_PATHS` (the ClientState module
//      itself + the Phoenix `phx:theme` toggle hook).
//   2. Any line where the offending call sits next to `"phx:theme"` — the
//      Phoenix theme fallback machinery reads that key from `root.html.heex`
//      inline JS and any hook that mirrors it needs a same-line escape.
//   3. Any line carrying the comment marker `client-state:allow` — the
//      documented escape hatch for one-shot legacy-key migration paths
//      (see `assets/README.md` "Lint gate" section for the contract).
//
// Exit codes:
//   0 — clean tree.
//   1 — one or more offending lines; the script prints each hit as
//       `<relative_path>:<line>: <trimmed_line>` on stderr before exiting.
//   2 — internal error (walking the tree failed); prints the error and
//       exits so a bad script doesn't silently gate green.

import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = fileURLToPath(new URL(".", import.meta.url));
// `scripts/` lives at `assets/scripts/`, so `assets/` is one level up.
const ASSETS_ROOT = resolve(SCRIPT_DIR, "..");
// Default scan root is `assets/js/`. Overridden by CLI arg for the self-test.
const SCAN_ROOT = process.argv[2]
  ? resolve(process.cwd(), process.argv[2])
  : join(ASSETS_ROOT, "js");

const OFFENDER = /\blocalStorage\s*\./;
const ALLOW_MARKER = "client-state:allow";
const PHX_THEME_MARKER = '"phx:theme"';

// Paths are stored as forward-slash relative-to-SCAN_ROOT for portability.
const ALLOWLISTED_PATHS = new Set([
  "client_state.js",
  "hooks/theme_toggle.js",
]);

// Extensions we scan. Kept narrow to avoid dragging in bundler / vendor code
// under `node_modules` (which is filtered by name too, but belt and braces).
const SCAN_EXTS = new Set([".js", ".mjs", ".ts", ".tsx"]);

const SKIP_DIRS = new Set(["node_modules", "vendor"]);

async function* walk(dir) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch (err) {
    throw new Error(`readdir ${dir}: ${err.message}`);
  }
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      yield* walk(full);
      continue;
    }
    if (!entry.isFile()) continue;
    const dot = entry.name.lastIndexOf(".");
    if (dot < 0) continue;
    const ext = entry.name.slice(dot);
    if (!SCAN_EXTS.has(ext)) continue;
    yield full;
  }
}

function toScanRelative(absolute) {
  const rel = relative(SCAN_ROOT, absolute);
  return rel.split(sep).join("/");
}

async function scanFile(absolute) {
  const scanRel = toScanRelative(absolute);
  if (ALLOWLISTED_PATHS.has(scanRel)) return [];
  const body = await readFile(absolute, "utf8");
  const lines = body.split(/\r?\n/);
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!OFFENDER.test(line)) continue;
    if (line.includes(ALLOW_MARKER)) continue;
    if (line.includes(PHX_THEME_MARKER)) continue;
    hits.push({ path: scanRel, line: i + 1, source: line.trim() });
  }
  return hits;
}

async function main() {
  try {
    const st = await stat(SCAN_ROOT);
    if (!st.isDirectory()) {
      console.error(`scan root is not a directory: ${SCAN_ROOT}`);
      process.exit(2);
    }
  } catch (err) {
    console.error(`scan root missing: ${SCAN_ROOT} (${err.message})`);
    process.exit(2);
  }

  const offences = [];
  try {
    for await (const abs of walk(SCAN_ROOT)) {
      const hits = await scanFile(abs);
      if (hits.length) offences.push(...hits);
    }
  } catch (err) {
    console.error(`walk failed: ${err.message}`);
    process.exit(2);
  }

  if (offences.length === 0) {
    process.exit(0);
  }

  console.error(
    `check_no_direct_localstorage: ${offences.length} offending line(s) — ` +
      "use Suite.ClientState (assets/js/client_state.js) instead."
  );
  for (const hit of offences) {
    console.error(`${hit.path}:${hit.line}: ${hit.source}`);
  }
  process.exit(1);
}

main();
