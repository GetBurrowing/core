import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * STYLESHEET GUARD for the task board on the OPEN iPhone Duo (task 01a20937
 * stage 1, direction canvas 01a2093b-50df).
 *
 * WHAT THIS PROTECTS. The open Duo is 669 or 951 CSS px wide, under `lg`, so
 * the board rendered the phone section list (`#tasks-mobile-list`) and hid
 * the kanban (`#kanban-board`, `hidden lg:flex`): no columns to scroll
 * between and every card a screen-wide row. app.css now shows the kanban in
 * the open posture as a row of FIXED 288px lanes.
 *
 * Every rule must:
 *   - sit under `:root[data-native-duo][data-native-duo-open]`, so the folded
 *     front screen (data-native-duo alone), regular iPhones and desktop are
 *     untouched;
 *   - be unlayered (no @layer, no @media ancestor), so it beats the Tailwind
 *     utilities it overrides (`hidden`, `lg:hidden`, `w-56`, `truncate`).
 * And no rule anywhere else may touch `#tasks-mobile-list` or
 * `#kanban-board`.
 *
 * The walker is the one from sheet_keyboard_stylesheet.test.js: it strips
 * comments (the rationale block quotes the selectors) and records the
 * at-rule chain around every rule.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const CSS_PATH = path.resolve(here, "../css/app.css");

const GATE = ":root[data-native-duo][data-native-duo-open]";
const BOARD = `${GATE} #kanban-board`;
const LANE = `${GATE} #kanban-board > [data-column]`;
const HEADER = `${LANE} > :first-child`;

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
          // Nested inside another style rule (CSS nesting) also counts as
          // not top-level.
          nested: stack.some((f) => !f.atRule),
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

/** Split a selector list on top-level commas (not inside parentheses). */
function selectors(list) {
  const out = [];
  let depth = 0;
  let cur = "";
  for (const c of list) {
    if (c === "(" || c === "[") depth++;
    if (c === ")" || c === "]") depth--;
    if (c === "," && depth === 0) {
      out.push(cur.trim());
      cur = "";
    } else {
      cur += c;
    }
  }
  if (cur.trim()) out.push(cur.trim());
  return out.map((s) => s.replace(/\s+/g, " "));
}

function rules() {
  const src = fs.readFileSync(CSS_PATH, "utf8");
  expect(src.length).toBeGreaterThan(1000);
  return parseRules(src);
}

/** The single top-level rule whose selector list contains `sel`. */
function ruleFor(sel) {
  const found = rules().filter((r) => selectors(r.selector).includes(sel));
  expect(found.length, `exactly one rule for ${sel}`).toBe(1);
  const [rule] = found;
  expect(rule.ancestors, `${sel} must be unlayered and outside any @media`).toEqual([]);
  expect(rule.nested).toBe(false);
  return rule;
}

const PX_ONLY = /^\d+px$/;

describe("app.css: the open iPhone Duo shows the kanban as fixed lanes", () => {
  it("SELF-CHECK: the walker sees an existing top-level Duo rule and a layered rule", () => {
    const all = rules();
    const strip = all.find((r) => r.selector === ":root[data-native-vertical-bar] [data-native-back]");
    expect(strip).toBeTruthy();
    expect(strip.ancestors).toEqual([]);
    expect(all.some((r) => r.ancestors.some((a) => a.startsWith("@layer")))).toBe(true);
    // The walker does not see commented-out text as a rule.
    expect(all.some((r) => r.selector.includes("task 01a20937"))).toBe(false);
  });

  it("1. hides the section list and shows the kanban as a horizontal scroller", () => {
    expect(decl(ruleFor(`${GATE} #tasks-mobile-list`).body, "display")).toBe("none");
    const board = ruleFor(BOARD).body;
    expect(decl(board, "display")).toBe("flex");
    expect(decl(board, "flex-direction")).toBe("row");
    expect(decl(board, "overflow-x")).toBe("auto");
    expect(decl(board, "padding-inline")).toBe("16px");
    expect(decl(board, "gap")).toBe("12px");
  });

  it("2. a lane is exactly 288px in px (never vw, rem or %) and does not flex", () => {
    const lane = ruleFor(LANE).body;
    for (const prop of ["width", "min-width", "max-width"]) {
      const v = decl(lane, prop);
      expect(v, prop).toBe("288px");
      expect(v).toMatch(PX_ONLY);
    }
    expect(decl(lane, "flex")).toBe("none");
  });

  it("3. every card and card group is the lane's inner width", () => {
    const sel = `${LANE} > :last-child > *`;
    const card = ruleFor(sel);
    expect(selectors(card.selector)).toContain(
      `${GATE} #kanban-board [data-role="task-card-group"] > [data-task-id]`
    );
    expect(decl(card.body, "width")).toBe("100%");
    expect(decl(card.body, "min-width")).toBe("0");
    expect(decl(card.body, "max-width")).toBe("100%");
  });

  it("4. unbreakable text: titles and meta wrap anywhere, titles clamp to 3 lines", () => {
    const title = ruleFor(`${BOARD} [data-role="card-title"]`);
    expect(selectors(title.selector)).toContain(`${BOARD} [data-stack-card] h3`);
    expect(decl(title.body, "overflow-wrap")).toBe("anywhere");
    expect(decl(title.body, "white-space")).toBe("normal");
    expect(decl(title.body, "-webkit-line-clamp")).toBe("3");
    expect(decl(title.body, "display")).toBe("-webkit-box");
    // Meta (and everything else in a card) inherits from the card rule.
    expect(decl(ruleFor(`${LANE} > :last-child > *`).body, "overflow-wrap")).toBe("anywhere");
  });

  it("5. horizontal scroll snap is proximity on the board and start on lanes", () => {
    const snap = decl(ruleFor(BOARD).body, "scroll-snap-type");
    expect(snap).toBe("x proximity");
    expect(snap).not.toMatch(/mandatory/);
    expect(decl(ruleFor(LANE).body, "scroll-snap-align")).toBe("start");
  });

  it("6. the column header is pinned and its name truncates before the count", () => {
    const header = ruleFor(HEADER).body;
    expect(decl(header, "position")).toBe("sticky");
    expect(decl(header, "top")).toBe("0");
    const name = ruleFor(`${HEADER} > h2`).body;
    expect(decl(name, "min-width")).toBe("0");
    expect(decl(name, "text-overflow")).toBe("ellipsis");
    expect(decl(ruleFor(`${HEADER} > :last-child`).body, "flex-shrink")).toBe("0");
  });

  it("7/8. trailing padding after the last lane, lanes packed at the inline start", () => {
    const board = ruleFor(BOARD).body;
    expect(decl(board, "padding-inline")).toBe("16px");
    expect(decl(board, "justify-content")).toBe("flex-start");
  });

  it("10. RTL: the inline axis uses logical properties only", () => {
    for (const r of rules().filter((r) => r.selector.includes(GATE))) {
      expect(r.body, r.selector).not.toMatch(/(?:^|[;\s])(?:padding|margin)-(?:left|right)\s*:/);
      expect(r.body, r.selector).not.toMatch(/(?:^|[;\s])(?:left|right)\s*:/);
    }
  });

  it("11. an open task detail panel hides the kanban as it hides the list", () => {
    const sel = `${GATE}:has([data-role="task-detail-panel"]) #kanban-board`;
    expect(decl(ruleFor(sel).body, "display")).toBe("none");
  });

  it("12. a sort control stays reachable: the lg-only one shows under the gate", () => {
    expect(decl(ruleFor(`${GATE} [data-role="board-sort-control"]`).body, "display")).toBe(
      "inline-flex"
    );
  });

  it("every new rule is gated on BOTH attributes; nothing else touches the list or the board", () => {
    const all = rules();
    const touching = all.flatMap((r) =>
      selectors(r.selector)
        .filter((s) => /#tasks-mobile-list|#kanban-board/.test(s))
        .map((s) => ({ s, r }))
    );
    expect(touching.length).toBeGreaterThanOrEqual(10);
    for (const { s, r } of touching) {
      expect(s.startsWith(GATE), `ungated selector: ${s}`).toBe(true);
      expect(r.ancestors, s).toEqual([]);
    }
  });

  it("no rule uses a viewport- or font-relative length for a lane", () => {
    const lane = ruleFor(LANE).body;
    expect(lane).not.toMatch(/\d(?:vw|vh|dvw|rem|em|%)/);
  });
});
