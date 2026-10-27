// Copy rule for the remote terminal (task 01a17b17 stage 3): it is a shell as
// the user on the user's own machine, and it is not a login flow. So the words
// sandbox, workspace, safe, isolated, scoped, login and "sign in" appear
// nowhere in what ships to the browser for it: the island bundle (xterm
// included, its CSS too) and the first-party sources. The rendered HTML is
// scanned by test/platform_web/live/terminal_live_test.exs.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const ASSETS = resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
const DEPS = resolve(ASSETS, "..", "deps");
const EXTRA = (process.env.NODE_PATH || "").split(":").filter(Boolean);
const BANNED = /\b(sandbox(?:ed|es)?|workspaces?|safe(?:ly|ty)?|isolat(?:ed|ion|e)|scoped|log[- ]?in|sign[- ]?in)\b/i;

test("the terminal island bundle and its stylesheet carry none of the banned words", async () => {
  const result = await build({
    absWorkingDir: ASSETS,
    entryPoints: ["js/terminal_island.js"],
    bundle: true,
    target: "es2022",
    write: false,
    outdir: "out",
    nodePaths: [DEPS, ...EXTRA],
  });
  assert.ok(result.outputFiles.length >= 2, "expected a .js and a .css output");
  for (const f of result.outputFiles) {
    const text = Buffer.from(f.contents).toString("utf8");
    const m = text.match(BANNED);
    assert.equal(m, null, `${f.path} contains ${m && JSON.stringify(m[0])}`);
  }
});

test("first-party terminal sources carry none of the banned words, comments included", () => {
  const files = [
    ...readdirSync(resolve(ASSETS, "js/terminal")).map((f) => resolve(ASSETS, "js/terminal", f)),
    resolve(ASSETS, "js/terminal_island.js"),
    resolve(ASSETS, "js/hooks/terminal_host.js"),
    resolve(ASSETS, "js/lib/load_terminal.js"),
  ];
  for (const f of files) {
    const m = readFileSync(f, "utf8").match(BANNED);
    assert.equal(m, null, `${f} contains ${m && JSON.stringify(m[0])}`);
  }
});
