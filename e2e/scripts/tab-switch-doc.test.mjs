// node --test e2e/scripts/tab-switch-doc.test.mjs
// Guards the per-destination table in docs/perf/tab-switch-baseline.md
// (task 01a17b00): one row per IconRail destination, no blank cells, a data
// source on every row, and every cell a number or an explicit marker.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const doc = readFileSync(path.join(root, "docs/perf/tab-switch-baseline.md"), "utf8");
const rail = readFileSync(path.join(root, "apps/platform/lib/platform_web/components/icon_rail.ex"), "utf8");

// IconRail key -> name used in the table's first column.
const NAME = { agents: "agents", context: "context" };

function tableRows() {
  const m = doc.match(/<!-- per-tab-table:start -->\n([\s\S]*?)\n<!-- per-tab-table:end -->/);
  assert.ok(m, "table markers missing");
  const lines = m[1].split("\n").filter((l) => l.startsWith("|"));
  const split = (l) => l.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
  return { header: split(lines[0]), rows: lines.slice(2).map(split) };
}

const MARKER = /^(not measurable: .+|pending deploy|unavailable on exp)$/;
const isNum = (c) => /^\d+(\.\d+)?$/.test(c);
const okPart = (p) => isNum(p) || MARKER.test(p);

test("the table has one local row per IconRail destination (tasks twice) and one exp row each", () => {
  const keys = [...new Set([...rail.matchAll(/key: :([a-z_]+)/g)].map((m) => m[1]))];
  assert.ok(keys.length >= 17, `found ${keys.length} IconRail keys`);
  const { rows } = tableRows();
  for (const source of ["local seeded", "exp"]) {
    const names = rows.filter((r) => r[r.length - 1] === source).map((r) => r[0]);
    for (const k of keys) {
      const want = NAME[k] || k;
      const n = names.filter((x) => x === want || x.startsWith(`${want} (`)).length;
      assert.equal(n, k === "tasks" ? 2 : 1, `${source}: rows for ${k}`);
    }
    assert.equal(names.length, keys.length + 1, `${source}: row count`);
  }
});

test("every cell is a number or an explicit marker, never blank, and every row names its source", () => {
  const { header, rows } = tableRows();
  assert.equal(header.length, 8);
  for (const r of rows) {
    assert.equal(r.length, header.length, `row ${r[0]} has ${r.length} cells`);
    assert.ok(["local seeded", "exp"].includes(r[7]), `${r[0]}: data source '${r[7]}'`);
    for (const c of r.slice(2, 7)) {
      assert.notEqual(c, "", `${r[0]}: blank cell`);
      for (const part of c.split(" / ")) assert.ok(okPart(part.trim()), `${r[0]}: bad cell '${c}'`);
    }
    // off / on columns carry both halves; the raw-bytes column carries one.
    for (const i of [2, 4, 5, 6]) {
      if (r[i].startsWith("not measurable") || r[i] === "unavailable on exp") continue;
      assert.equal(r[i].split(" / ").length, 2, `${r[0]}: column ${i} needs off and on`);
    }
  }
});

test("local rows that were measured carry no pending or unavailable markers", () => {
  const { rows } = tableRows();
  for (const r of rows.filter((x) => x[7] === "local seeded" && !x[2].startsWith("not measurable"))) {
    for (const c of r.slice(2, 7)) assert.ok(!/pending deploy|unavailable on exp/.test(c), `${r[0]}: '${c}'`);
  }
});
