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

// Task 01a17bf4 stage 4: the before/after table in
// docs/perf/tab-switch-first-frame.md. One row per measured tab (the literal
// list below, cross-checked against the data file's before-run), no blank
// cells, every cell "before / after" with both halves numeric, and chat's
// after first-frame KiB and tap must be numbers.
const FF_DOC = path.join(root, "docs/perf/tab-switch-first-frame.md");
const FF_DATA = path.join(root, "docs/perf/tab-switch-first-frame.data.json");
const FF_ROWS = [
  "chat|1280x800", "chat|390x844", "voice|1280x800", "tasks|1280x800", "meetings|1280x800",
  "inbox|1280x800", "files|1280x800", "canvases|1280x800", "skills|1280x800", "org_memory|1280x800",
  "control|1280x800", "experiments|1280x800", "changelog|1280x800", "settings|1280x800",
];

function markedTable(text, name) {
  const m = text.match(new RegExp(`<!-- ${name}:start -->\\n([\\s\\S]*?)\\n<!-- ${name}:end -->`));
  assert.ok(m, `${name} markers missing`);
  const lines = m[1].split("\n").filter((l) => l.startsWith("|"));
  const split = (l) => l.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
  return { header: split(lines[0]), rows: lines.slice(2).map(split) };
}

const halves = (c) => c.split(" / ").map((p) => p.trim());
const num = (c) => /^[+-]?\d+(\.\d+)?$/.test(c);

test("first-frame table: one row per measured tab, every cell before / after and numeric", () => {
  const doc = readFileSync(FF_DOC, "utf8");
  const { header, rows } = markedTable(doc, "first-frame-table");
  assert.equal(header.length, 6, "tab | viewport | mount us | first-frame KiB | tap median | tap p90");
  const got = rows.map((r) => `${r[0]}|${r[1]}`);
  for (const want of FF_ROWS) assert.equal(got.filter((g) => g === want).length, 1, `row for ${want}`);
  assert.equal(rows.length, FF_ROWS.length, "row count");

  const data = JSON.parse(readFileSync(FF_DATA, "utf8"));
  const beforeKeys = data.runs.before.tabs.map((t) => t.summary.key);
  for (const k of beforeKeys) assert.ok(got.includes(`${k}|1280x800`), `before-run tab ${k} has no row`);

  for (const r of rows) {
    assert.equal(r.length, header.length, `row ${r[0]} ${r[1]} has ${r.length} cells`);
    for (const c of r.slice(2)) {
      assert.notEqual(c, "", `${r[0]} ${r[1]}: blank cell`);
      const h = halves(c);
      assert.equal(h.length, 2, `${r[0]} ${r[1]}: '${c}' needs before / after`);
      for (const p of h) assert.ok(num(p), `${r[0]} ${r[1]}: '${c}' is not numeric`);
    }
  }
});

test("first-frame table: chat's after first-frame KiB and tap are numbers", () => {
  const { rows } = markedTable(readFileSync(FF_DOC, "utf8"), "first-frame-table");
  const chat = rows.find((r) => r[0] === "chat" && r[1] === "1280x800");
  assert.ok(chat, "chat 1280x800 row missing");
  for (const i of [3, 4, 5]) assert.ok(Number.isFinite(Number(halves(chat[i])[1])), `chat after column ${i}: '${chat[i]}'`);
});

test("first-frame doc: chat attribution before and after, local-not-prod statement, 288 ms rule", () => {
  const doc = readFileSync(FF_DOC, "utf8");
  const { header, rows } = markedTable(doc, "chat-attribution");
  assert.equal(header.length, 8, "run | tap | server | client main thread | RTT | transfer (wire KiB) | sum | gap");
  for (const run of ["before", "after"]) {
    const r = rows.find((x) => x[0] === `chat ${run}`);
    assert.ok(r, `chat ${run} attribution row missing`);
    for (const c of r.slice(1)) assert.ok(num(c.split(" ")[0]), `chat ${run}: '${c}'`);
  }
  assert.match(doc, /local seeded, shaped link, not prod/);
  assert.match(doc, /288 ms/);
});
