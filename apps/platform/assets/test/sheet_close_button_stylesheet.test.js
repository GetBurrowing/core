import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * STYLESHEET GUARD for the sheet header X (`.sheet-close-button`, task
 * 01a161c4 stage 2).
 *
 * WHAT THIS PROTECTS. The phone-list palette ruling: no hover paint on phone
 * surfaces. The X's markup carries no `hover:` utility (so the markup scans in
 * the LiveView tests stay clean); its desktop hover is a plain CSS rule that
 * must sit inside BOTH a `(hover: hover)` and a `min-width >= 1024px` media
 * condition. A copy at top level, or behind only one of the two conditions,
 * paints hover on a phone (a touch tap leaves a sticky :hover; a wide
 * touch-only tablet matches min-width alone).
 *
 * WHY A WALKER AND NOT A REGEX. The property is "which at-rules enclose this
 * rule", which a substring scan cannot see, and app.css names
 * `.sheet-close-button` inside comments, which a scan would read as rules.
 * The walker mirrors hooks/jump_anchor_stylesheet.test.js: comments are
 * blanked (offsets preserved), brace depth tracked, each rule recorded with
 * its enclosing at-rule chain.
 *
 * ANTI-VACUITY. The hover rule must EXIST (an absent rule satisfies "every
 * occurrence is gated" trivially), and the positive control proves the walker
 * reports `.sheet-handle-button` at top level, so it can tell top level from
 * media-gated.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const CSS_PATH = path.resolve(here, "../css/app.css");

/** Blank out /* … *​/ comments, preserving length so offsets stay meaningful. */
function stripComments(src) {
  let out = "";
  let i = 0;
  while (i < src.length) {
    if (src[i] === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2);
      const stop = end === -1 ? src.length : end + 2;
      for (let k = i; k < stop; k++) out += src[k] === "\n" ? "\n" : " ";
      i = stop;
    } else {
      out += src[i];
      i++;
    }
  }
  return out;
}

/** Every rule with the chain of at-rules enclosing it. */
function parseRules(src) {
  const clean = stripComments(src);
  const rules = [];
  const stack = [];
  let prelude = "";

  for (let i = 0; i < clean.length; i++) {
    const c = clean[i];
    if (c === "{") {
      const text = prelude.trim();
      const frame = { text, atRule: text.startsWith("@"), bodyStart: i + 1 };
      if (!frame.atRule) {
        rules.push({
          selector: text,
          bodyStart: i + 1,
          ancestors: stack.filter((f) => f.atRule).map((f) => f.text),
        });
      }
      stack.push(frame);
      prelude = "";
    } else if (c === "}") {
      const frame = stack.pop();
      if (frame && !frame.atRule) {
        const rule = rules.find((r) => r.bodyStart === frame.bodyStart);
        if (rule) rule.body = clean.slice(frame.bodyStart, i);
      }
      prelude = "";
    } else if (c === ";" && stack.length === 0) {
      prelude = "";
    } else {
      prelude += c;
    }
  }
  return rules;
}

const selectorsOf = (rule) => rule.selector.split(",").map((s) => s.trim());

const hasHoverHover = (rule) =>
  rule.ancestors.some(
    (a) => a.startsWith("@media") && /\(\s*hover\s*:\s*hover\s*\)/.test(a),
  );

const hasDesktopMinWidth = (rule) =>
  rule.ancestors.some((a) => {
    if (!a.startsWith("@media")) return false;
    const m = a.match(/\(\s*min-width\s*:\s*(\d+(?:\.\d+)?)px\s*\)/);
    return m !== null && Number(m[1]) >= 1024;
  });

function readSource() {
  const src = fs.readFileSync(CSS_PATH, "utf8");
  expect(src.length).toBeGreaterThan(1000);
  expect(src).toContain(".sheet-handle-button");
  return src;
}

describe("app.css — the sheet X's hover is desktop-only", () => {
  it("CONTROL: the walker reports .sheet-handle-button at top level and a media-gated copy of the same selector family", () => {
    const rules = parseRules(readSource());
    expect(rules.length).toBeGreaterThan(100);

    const handle = rules.filter((r) =>
      selectorsOf(r).includes(".sheet-handle-button"),
    );
    expect(handle).toHaveLength(1);
    expect(handle[0].ancestors).toEqual([]);

    // The same walker sees a media-gated rule in the same family: the
    // `min-width: 768px` keep-visible rule for the handle bar.
    const gatedHandle = rules.filter(
      (r) =>
        r.selector.includes(".sheet-handle-button") &&
        r.ancestors.some((a) => a.includes("min-width: 768px")),
    );
    expect(gatedHandle.length).toBeGreaterThan(0);
  });

  it("a .sheet-close-button:hover rule exists, and every occurrence sits inside (hover: hover) AND min-width >= 1024px", () => {
    const rules = parseRules(readSource());
    const hover = rules.filter((r) =>
      selectorsOf(r).some(
        (s) => s.includes(".sheet-close-button") && s.includes(":hover"),
      ),
    );

    // Anti-vacuity: the rule the ruling requires is there.
    expect(hover.length).toBeGreaterThan(0);

    const ungated = hover.filter(
      (r) => !(hasHoverHover(r) && hasDesktopMinWidth(r)),
    );
    expect(
      ungated.map(
        (r) => `${r.selector}  <<inside>>  ${r.ancestors.join(" / ") || "(top level)"}`,
      ),
    ).toEqual([]);

    // Semantic tokens only: no colour literal in its body.
    for (const r of hover) {
      expect(r.body).not.toMatch(/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\boklch\(/);
    }
  });

  it("no .sheet-close-button rule is qualified by data-theme", () => {
    const rules = parseRules(readSource());
    const close = rules.filter((r) => r.selector.includes(".sheet-close-button"));
    expect(close.length).toBeGreaterThan(0);
    expect(close.filter((r) => r.selector.includes("data-theme"))).toEqual([]);
  });
});
