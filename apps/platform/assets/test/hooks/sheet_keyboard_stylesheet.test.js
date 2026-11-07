import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * STYLESHEET GUARD for the keyboard-aware bottom sheet.
 *
 * WHAT THIS PROTECTS. On a phone, iOS does not shrink the layout viewport for
 * the soft keyboard, so a bottom sheet pinned at `bottom: 0` with a
 * `90vh` cap puts its focused field under the keyboard. The Sheet hook runs
 * `watchKeyboard`, which publishes `data-keyboard-open`, `--keyboard-inset`
 * and `--visual-viewport-h` on <html>. The rule this guards consumes them:
 * the panel rises by the inset and is clamped to the visible height minus
 * the safe-area top, so the handle's Close control stays clear of the notch.
 *
 * Phone only: the rule must sit inside `@media (max-width: 767.98px)`, so the
 * desktop card and popovers are untouched. It must also be unlayered, or the
 * unlayered per-sheet panel rules (the Chat list search sheet's 85dvh
 * min-height) beat it.
 *
 * The walker is the one from jump_anchor_stylesheet.test.js: it strips
 * comments (this rule's rationale block quotes its own selector) and records
 * the at-rule chain around every rule.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const CSS_PATH = path.resolve(here, "../../css/app.css");

const SELECTOR = ":root[data-keyboard-open] .sheet-bottom .sheet-panel";
const PHONE = "@media (max-width: 767.98px)";

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

/**
 * Walk the stylesheet and return every rule with the at-rule chain enclosing
 * it. A "rule" is any prelude followed by `{`; at-rules (`@media`, `@keyframes`,
 * `@layer`, …) are recorded as ancestors rather than as rules of their own.
 */
function parseRules(src) {
  const clean = stripComments(src);
  const rules = [];
  const stack = [];
  let prelude = "";
  let preludeStart = 0;

  for (let i = 0; i < clean.length; i++) {
    const c = clean[i];
    if (c === "{") {
      const text = prelude.trim();
      const frame = { text, start: preludeStart, bodyStart: i + 1 };
      if (text.startsWith("@")) {
        frame.atRule = true;
      } else {
        frame.atRule = false;
        rules.push({
          selector: text,
          start: preludeStart,
          bodyStart: i + 1,
          ancestors: stack.filter((f) => f.atRule).map((f) => f.text),
        });
      }
      stack.push(frame);
      prelude = "";
      preludeStart = i + 1;
    } else if (c === "}") {
      const frame = stack.pop();
      if (frame && !frame.atRule) {
        const rule = rules.find((r) => r.bodyStart === frame.bodyStart);
        if (rule) rule.body = clean.slice(frame.bodyStart, i);
      }
      prelude = "";
      preludeStart = i + 1;
    } else if (c === ";" && stack.length === 0) {
      prelude = "";
      preludeStart = i + 1;
    } else {
      if (prelude === "") preludeStart = i;
      prelude += c;
    }
  }
  return rules;
}

const decl = (body, prop) => {
  const m = body.match(new RegExp(`(?:^|;|\\s)${prop}\\s*:\\s*([^;]+)`));
  return m ? m[1].trim() : null;
};

function rules() {
  const src = fs.readFileSync(CSS_PATH, "utf8");
  expect(src.length).toBeGreaterThan(1000);
  expect(src).toContain(".sheet-bottom .sheet-panel");
  return parseRules(src);
}

describe("app.css: a phone bottom sheet rises above the soft keyboard", () => {
  it("SELF-CHECK: the walker sees the base sheet rule and its desktop override", () => {
    const all = rules();
    const base = all.filter((r) => r.selector === ".sheet-bottom .sheet-panel");
    // One in @layer components with no media, one inside the >= 768px query.
    expect(base.some((r) => !r.ancestors.some((a) => a.startsWith("@media")))).toBe(true);
    expect(base.some((r) => r.ancestors.includes("@media (min-width: 768px)"))).toBe(true);
    expect(decl(base.find((r) => r.ancestors.length === 1).body, "bottom")).toBe("0");
  });

  it("the keyboard rule exists only inside the phone media block, unlayered", () => {
    const found = rules().filter((r) => r.selector === SELECTOR);
    expect(found.length).toBe(1);
    expect(found[0].ancestors).toEqual([PHONE]);
  });

  it("lifts the panel by --keyboard-inset", () => {
    const [rule] = rules().filter((r) => r.selector === SELECTOR);
    expect(decl(rule.body, "bottom")).toMatch(/^var\(--keyboard-inset\b/);
  });

  it("clamps max-height to the visible height less the safe-area top", () => {
    const [rule] = rules().filter((r) => r.selector === SELECTOR);
    const maxH = decl(rule.body, "max-height");
    expect(maxH).toContain("var(--visual-viewport-h");
    expect(maxH).toContain("env(safe-area-inset-top");
  });

  it("the Chat list search sheet's min-height is clamped by the same expression", () => {
    const found = rules().filter(
      (r) => r.selector === ":root[data-keyboard-open] .chat-list-search-sheet .sheet-panel"
    );
    expect(found.length).toBe(1);
    expect(found[0].ancestors).toEqual([PHONE]);
    const minH = decl(found[0].body, "min-height");
    expect(minH).toContain("var(--visual-viewport-h");
    expect(minH).toContain("env(safe-area-inset-top");
  });
});
