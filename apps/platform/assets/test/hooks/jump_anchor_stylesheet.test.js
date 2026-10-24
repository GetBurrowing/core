import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * STYLESHEET REGRESSION GUARD for the jump-to-latest control (task 01a0419a
 * stage 4).
 *
 * WHAT THIS PROTECTS. Canvas r37 desktop ruling 2: the chip's hit area is
 * unconditional, and reintroducing ANY width-, hover- or pointer-gated rule on
 * `.chat-jump*` reintroduces the defect this component already shipped once —
 * a 44px floor gated behind `@media (hover: none)`, which the review harness
 * could not produce, so it passed green while being wrong on every real
 * device. The ruling's own words: reintroducing a width condition reintroduces
 * the defect in a new costume. So the guard is not "no `@media (hover: none)`"
 * — it is "no media query of any kind touches these selectors".
 *
 * WHY A REAL WALKER AND NOT A REGEX. Two independent reasons, and each one
 * alone would sink a substring scan:
 *
 * 1. A substring match cannot tell a top-level rule from one nested inside an
 *    `@media` block. That distinction IS the property under test, so a scan
 *    that cannot see it is not a weaker version of this test — it is a test of
 *    nothing. The walker below tracks brace depth and records, for every rule,
 *    the chain of at-rules enclosing it.
 *
 * 2. `app.css` mentions `.chat-jump-chip`, `.chat-jump-chip-pill` and
 *    `.chat-jump-anchor-row` MANY times inside /* comments *​/ — the long
 *    rationale blocks above the rules. A scanner that does not strip comments
 *    reads those as selectors and reports rules that do not exist. Comments
 *    are blanked to spaces (not removed) so every recorded byte offset still
 *    indexes the original source and a failure message can cite a real line.
 *
 * ANTI-VACUITY. Every assertion here is an ABSENCE except where noted, and an
 * absence is exactly what a broken scanner, a wrong path, or an empty string
 * also produces. The controls are therefore not optional decoration:
 *
 *   - `readSource` asserts the file is non-empty and contains the marker
 *     selector before any structural claim is made. `readFileSync` throws on a
 *     missing path, but a file that MOVED and left a stub, or a glob that
 *     resolved to the wrong asset, would hand the scanner an empty string and
 *     every "no `.chat-jump` rule inside a media query" assertion would pass.
 *   - The `.bottom-nav` control asserts the walker reports the SAME selector
 *     text as top-level in one place and media-gated in another. That kills
 *     both directions of scanner bug at once: one that calls everything
 *     top-level (which would make the main assertion vacuous) and one that
 *     calls everything media-gated (which would make it fail loudly, but for
 *     the wrong reason).
 *   - The `:hover` control asserts the hover rule EXISTS. "No hover rule
 *     inside a media query" is trivially true of a stylesheet with no hover
 *     rule at all, which is the state canvas r37 ruling 4 forbids.
 *   - The comment control asserts the walker found strictly FEWER `.chat-jump`
 *     selectors than the raw text contains occurrences, which is only true if
 *     comment stripping actually ran.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const CSS_PATH = path.resolve(here, "../../css/app.css");

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

const inMedia = (rule) => rule.ancestors.some((a) => a.startsWith("@media"));

function readSource() {
  const src = fs.readFileSync(CSS_PATH, "utf8");
  // Prove the scanner is looking at the file it thinks it is, BEFORE any
  // assertion whose pass condition is an absence.
  expect(src.length).toBeGreaterThan(1000);
  expect(src).toContain(".chat-jump-anchor-row");
  return src;
}

describe("app.css — the jump-to-latest control is unconditional", () => {
  it("SELF-CHECK: the walker discriminates media-gated from top-level on one selector, and ignores comments", () => {
    const src = readSource();
    const rules = parseRules(src);

    // The walker found a plausible stylesheet at all.
    expect(rules.length).toBeGreaterThan(100);

    // `.bottom-nav` is declared BOTH at top level (the sticky bar) and inside
    // `@media (min-width: 1024px)` (the desktop hide). Same selector text, two
    // answers required — so neither "everything is top-level" nor "everything
    // is media-gated" can satisfy this.
    const bottomNav = rules.filter((r) => r.selector === ".bottom-nav");
    expect(bottomNav.length).toBeGreaterThanOrEqual(2);
    expect(bottomNav.some((r) => inMedia(r))).toBe(true);
    expect(bottomNav.some((r) => !inMedia(r))).toBe(true);

    // And one media-gated copy really is the desktop hide, so this control is
    // pinned to a rule with a reason to exist rather than to a coincidence.
    // Since the glass bar (task 01a1557a-7a71) `.bottom-nav` also sits inside
    // reduced-transparency and reduced-motion queries, so the desktop hide is
    // looked up by its query rather than taken as the first gated copy.
    const hidden = bottomNav.find(
      (r) => inMedia(r) && r.ancestors.join(" ").includes("min-width: 1024px"),
    );
    expect(hidden).toBeDefined();
    expect(hidden.body).toContain("display: none");

    // Comment stripping ran. `.chat-jump` appears far more often in the raw
    // text than there are rules, because of the rationale comments; if the
    // walker were reading comments these two numbers would converge.
    const rawOccurrences = src.split(".chat-jump").length - 1;
    const selectorRules = rules.filter((r) =>
      r.selector.includes(".chat-jump"),
    );
    expect(selectorRules.length).toBeGreaterThan(0);
    expect(selectorRules.length).toBeLessThan(rawOccurrences);
  });

  it("no .chat-jump rule sits inside any @media block, of any kind", () => {
    const rules = parseRules(readSource());
    const jump = rules.filter((r) => r.selector.includes(".chat-jump"));

    // Anti-vacuity: there ARE such rules to be wrong about.
    expect(jump.length).toBeGreaterThan(0);

    const gated = jump.filter((r) => inMedia(r));
    // Named, so a failure says WHICH rule and under WHICH query rather than
    // "expected 1 to be 0".
    expect(
      gated.map((r) => `${r.selector}  <<inside>>  ${r.ancestors.join(" / ")}`),
    ).toEqual([]);
  });

  it(".chat-jump-anchor-row is absolutely positioned and click-through AT TOP LEVEL", () => {
    const rules = parseRules(readSource());
    const row = rules.filter((r) => r.selector === ".chat-jump-anchor-row");

    expect(row).toHaveLength(1);
    expect(row[0].ancestors).toEqual([]);
    expect(row[0].body).toMatch(/position:\s*absolute/);
    expect(row[0].body).toMatch(/pointer-events:\s*none/);
  });

  it("CONTROL: the hover affordance exists as a plain selector, not a media-gated one", () => {
    // Canvas r37 ruling 4 requires a hover state AND requires it to be a plain
    // CSS `:hover`, not Tailwind's media-gated `hover:` variant. Without this
    // assertion the media-query guard above passes trivially on a stylesheet
    // that simply has no hover rule.
    const rules = parseRules(readSource());
    const hover = rules.filter(
      (r) =>
        r.selector.includes(".chat-jump-chip") && r.selector.includes(":hover"),
    );

    expect(hover.length).toBeGreaterThan(0);
    expect(hover.every((r) => !inMedia(r))).toBe(true);
    // Paired with :focus-visible so keyboard users get the same affordance.
    expect(hover.some((r) => r.selector.includes(":focus-visible"))).toBe(true);
  });

  it("the shared 1023.98px breakpoint survives, and governs only the bottom nav and its clearance", () => {
    // NOT "zero occurrences of 1023.98". It is the shared mobile breakpoint and
    // deleting it would break an unrelated live rule. What matters is that no
    // occurrence of it reaches a `.chat-jump` selector — which the media-query
    // test above already guarantees in general. This pins the specific
    // occurrence so that a future edit re-gating the chip at this exact
    // breakpoint has to walk past a named assertion.
    const src = readSource();
    const rules = parseRules(src);

    const gated = rules.filter((r) =>
      r.ancestors.some((a) => a.includes("1023.98")),
    );
    // Task 01a1557a-7a71 stage 3: the floating tab bar's clearance. The
    // token rule is keyed on the bar's presence, and the two consumers that
    // pad a scroll END by it sit at the same breakpoint. Still bottom-nav
    // only, and still no `.chat-jump` selector.
    //
    // Task 01a15f2e stages 2 and 3 add the phone composer pill and the chat
    // dock at the same breakpoint (Saru's canvas 01a15f2f). Still no
    // `.chat-jump` selector: the jump chip floats over the dock unchanged.
    //
    // 2026-10-23 (sponsor feedback): Send's disc inside the pill, the controls'
    // bottom alignment, the staged tray's inset, and the dock's soft-keyboard
    // rule. Send feel "4g" adds the phone disc's flash and ring inset.
    // Still no `.chat-jump` selector.
    expect(gated.map((r) => r.selector)).toEqual([
      ".compose-input-area",
      ":root .compose-input-area .compose-pill-bar",
      ".compose-input-area .compose-pill-bar:not(:focus-within)",
      ".compose-input-area .compose-pill-attach,\n  .compose-input-area .compose-pill-send",
      ".compose-input-area .compose-pill-attach::after,\n  .compose-input-area .compose-pill-send::after",
      ".compose-input-area .compose-pill-send",
      ".compose-input-area .compose-pill-send",
      ".compose-input-area .compose-pill-send::before",
      ".compose-input-area .compose-pill-send:disabled::before",
      ":root[data-send-go] .compose-input-area .compose-pill-send",
      ":root[data-send-go] .compose-input-area .compose-pill-send::before",
      ".compose-input-area .compose-pill-send .send-ring",
      ".compose-input-area .compose-pill-attach,\n  .compose-input-area .compose-mention-button,\n  .compose-input-area .compose-pill-send",
      '.compose-input-area [data-role="staged-area"]',
      ".compose-input-area .compose-pill-bar textarea:placeholder-shown,\n  .compose-input-area .compose-pill-bar textarea::placeholder",
      ":root .compose-input-area .compose-pill-bar",
      "#chat-drop-zone:has(> .chat-dock--glass)",
      ".chat-dock.chat-dock--glass",
      ".chat-dock--glass > *",
      ":root[data-keyboard-open] .chat-dock.chat-dock--glass",
      ".chat-dock--glass .compose-input-area",
      '.chat-dock--glass > [data-role="typing-indicator"]',
      '.chat-dock--glass > [data-role="typing-indicator"]',
      '[data-preset="high-contrast"] .chat-dock--glass > [data-role="typing-indicator"]',
      "#chat-drop-zone:has(> .chat-dock--glass) #message-list",
      ":root:has([data-bottom-rail])",
      ".compose-input-area",
      ".sheet-panel .compose-input-area",
      ".clears-tab-bar",
    ]);
    const token = gated.find((r) => r.selector === ":root:has([data-bottom-rail])");
    expect(token.body).toContain("--bottom-nav-height");
    expect(gated.every((r) => !r.selector.includes(".chat-jump"))).toBe(true);
  });
});
