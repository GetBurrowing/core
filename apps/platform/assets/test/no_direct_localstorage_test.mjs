// Self-test for `scripts/check_no_direct_localstorage.mjs` (task 019f3e9a
// stage 4). We drive the real script against synthetic fixture trees and
// assert on its exit code + stderr so a broken check-script fails CI here
// before the real repo-wide scan gets a chance to hide the regression.
//
// Fixtures live under an OS-managed tmpdir per assertion — the script's
// scan root is passed as `process.argv[2]`, which we thread through to
// `node <script> <tmpdir>` rather than mutating the on-disk repo.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const SCRIPT_PATH = resolve(HERE, "..", "scripts", "check_no_direct_localstorage.mjs");

function runScript(scanRoot) {
  return new Promise((resolvePromise) => {
    const child = spawn("node", [SCRIPT_PATH, scanRoot], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("close", (code) => {
      resolvePromise({ code, stdout, stderr });
    });
  });
}

async function makeFixture(files) {
  const dir = await mkdtemp(join(tmpdir(), "clientstate-lint-"));
  for (const [relPath, content] of Object.entries(files)) {
    const abs = join(dir, relPath);
    const parent = abs.substring(0, abs.lastIndexOf("/"));
    if (parent && parent !== dir) {
      await mkdir(parent, { recursive: true });
    }
    await writeFile(abs, content, "utf8");
  }
  return dir;
}

test("check_no_direct_localstorage exits 0 on a clean tree", async () => {
  const fixture = await makeFixture({
    "app.js": "console.log('hi')\n",
    "hooks/other.js":
      "import ClientState from './client_state';\n" +
      "export const x = () => ClientState.get('ns', 'k');\n",
    "hooks/theme_picker.js":
      // Not the allowlisted path (fixture root != real assets), but has the
      // `\"burrow-theme-v1\"` marker on the same line as the offending call. This
      // exercises the same-line escape hatch.
      'const t = localStorage.getItem("burrow-theme-v1");\n',
  });
  try {
    const result = await runScript(fixture);
    assert.equal(result.code, 0, `expected exit 0, stderr: ${result.stderr}`);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("check_no_direct_localstorage exits 1 on a direct-store call in a fake hook", async () => {
  const fixture = await makeFixture({
    "hooks/rogue.js":
      "// A hook that skips ClientState — should be flagged.\n" +
      'localStorage.setItem("suite:rogue:x", "1");\n',
  });
  try {
    const result = await runScript(fixture);
    assert.equal(result.code, 1, `expected exit 1, stderr: ${result.stderr}`);
    assert.match(result.stderr, /hooks\/rogue\.js:2:/);
    assert.match(result.stderr, /Suite\.ClientState/);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("check_no_direct_localstorage honours the `client-state:allow` marker", async () => {
  const fixture = await makeFixture({
    "hooks/migrator.js":
      "// Legacy-key migration path — carries the same-line escape marker.\n" +
      'const legacy = localStorage.getItem("suite:old"); // client-state:allow (legacy migration)\n' +
      'localStorage.removeItem("suite:old"); // client-state:allow (legacy migration)\n',
  });
  try {
    const result = await runScript(fixture);
    assert.equal(result.code, 0, `expected exit 0, stderr: ${result.stderr}`);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});

test("check_no_direct_localstorage flags multiple offenders and lists each", async () => {
  const fixture = await makeFixture({
    "hooks/one.js": 'localStorage.setItem("suite:a:x", "1");\n',
    "hooks/two.js": 'const v = localStorage.getItem("suite:b:y");\n',
  });
  try {
    const result = await runScript(fixture);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /2 offending line\(s\)/);
    assert.match(result.stderr, /hooks\/one\.js:1:/);
    assert.match(result.stderr, /hooks\/two\.js:1:/);
  } finally {
    await rm(fixture, { recursive: true, force: true });
  }
});
