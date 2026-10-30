/**
 * No legacy SUITE_ environment name anywhere in services/agent-host (task 01a18dab).
 *
 * The Burrow rename finished here: agent-host reads BURROW_CORE_URL only, its
 * units write BURROW_AGENT_ID / BURROW_AGENT_SESSION / BURROW_UNATTENDED only,
 * and versions.env pins BURROW_CLI_REF. This guard fails on any token matching
 * (?<![A-Z0-9_])SUITE_[A-Z0-9_]+ in a file under this directory unless the
 * name is on KEEP below, with its reason.
 *
 * The lookbehind (not \b) is deliberate: in an escaped string such as a newline
 * escape followed by the name, the `n` is a word character, so \b finds no
 * boundary and a \b scan misses it (the positive control checks that case).
 *
 * This file builds the prefix at runtime so it cannot trip itself.
 */
import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const PREFIX = ["SUITE", ""].join("_");
const TOKEN = new RegExp(`(?<![A-Z0-9_])${PREFIX}[A-Z0-9_]+`, "g");

/** Name -> reason. Empty: inventory on 2026-10-30 found no box that sets only a SUITE_ name. */
const KEEP: Record<string, string> = {};

const SKIP_DIRS = new Set(["node_modules", ".git"]);

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (SKIP_DIRS.has(name)) continue;
    const p = join(dir, name);
    const s = statSync(p);
    if (s.isDirectory()) walk(p, out);
    else if (s.isFile()) out.push(p);
  }
  return out;
}

export function offenders(files: string[], keep: Record<string, string> = KEEP): string[] {
  const hits: string[] = [];
  for (const file of files) {
    const lines = readFileSync(file, "utf8").split("\n");
    lines.forEach((line, i) => {
      for (const m of line.matchAll(TOKEN)) {
        if (!(m[0] in keep)) hits.push(`${relative(ROOT, file)}:${i + 1}:${m[0]}`);
      }
    });
  }
  return hits;
}

describe("legacy SUITE_ env names in services/agent-host", () => {
  const files = walk(ROOT);

  test("positive control: the scan sees the tree, and the token regex fires", () => {
    expect(files.length).toBeGreaterThan(20);
    expect(files.some((f) => f.endsWith(join("src", "main.ts")))).toBe(true);
    const probe = `${PREFIX}PROBE_X`;
    expect(`x = "\\n${probe}"`.match(TOKEN)).toEqual([probe]);
    expect(`BURROW_${probe}`.match(TOKEN)).toBeNull();
  });

  test("every SUITE_ token is on the keep-list (which is empty)", () => {
    const hits = offenders(files);
    if (hits.length > 0) throw new Error(`legacy SUITE_ env names found:\n${hits.join("\n")}`);
    expect(hits).toEqual([]);
  });

  test("every keep-list entry still occurs, so the list cannot rot", () => {
    const seen = new Set(offenders(files, {}).map((h) => h.split(":").pop()));
    for (const name of Object.keys(KEEP)) expect([name, seen.has(name)]).toEqual([name, true]);
  });
});
