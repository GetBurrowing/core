// CSS guard: the reaction picker must be INVISIBLE AND UNCLICKABLE when closed.
//
// `#reaction-picker` is always mounted as of task 019e0814 stage 3, because the
// JS hook builds its ~1,850-tile grid once and that grid has to survive a
// close. What that permanently parks in the DOM is a full-viewport `inset-0`
// scrim carrying `phx-click="close_reaction_picker"`.
//
// The rule used to be `.reaction-picker { display: flex }` with no condition.
// Left that way, the picker would ship an INVISIBLE CLICK-EATER over the entire
// chat surface: every message stops responding to clicks, and nothing looks
// wrong — no error, no visual, nothing a screenshot review would catch. This
// pins the mechanism that prevents it.
//
// It is a CSS assertion and not a DOM one on purpose: `chat_live_test.exs`
// already pins the markup side (`data-open="false"` plus `inert`), and neither
// side alone is sufficient. Correct markup with `display: flex` on the closed
// state is the exact bug.
//
// Verified to FAIL under mutation: restoring the unconditional
// `.reaction-picker { display: flex; }` fires the first two assertions.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const RAW = readFileSync(resolve(HERE, "..", "css", "app.css"), "utf8");

// Comments are stripped before anything else. This stylesheet documents its own
// rules in prose, and several of those comments quote CSS verbatim — including
// the `.reaction-picker { display: flex }` that this file exists to forbid. A
// parser that read comments would find the forbidden rule in the paragraph
// explaining why it is forbidden.
const CSS = RAW.replace(/\/\*[\s\S]*?\*\//g, "");

// Flat rule extractor. `[^{}]` cannot span a nested block, so rules inside an
// `@media` are matched individually and the at-rule prelude is skipped — which
// is what we want: the guard is about selectors and declarations, not about
// which media query they sit in.
function rules() {
  const out = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m;
  while ((m = re.exec(CSS)) !== null) {
    out.push({ selector: m[1].trim(), body: m[2], index: m.index });
  }
  return out;
}

function displayOf(body) {
  const m = /(?:^|;)\s*display\s*:\s*([^;]+)/.exec(body);
  return m ? m[1].trim() : null;
}

test("the closed picker is display:none, never an unconditional flex", () => {
  const bare = rules().filter((r) => r.selector === ".reaction-picker");
  assert.ok(bare.length > 0, "no bare `.reaction-picker` rule found at all");

  const withDisplay = bare.filter((r) => displayOf(r.body) !== null);
  assert.equal(
    withDisplay.length,
    1,
    `expected exactly one bare .reaction-picker rule to set display, found ${withDisplay.length}`
  );
  assert.equal(
    displayOf(withDisplay[0].body),
    "none",
    "the unconditional `.reaction-picker` display must be `none` — anything else " +
      "puts the always-mounted inset-0 scrim over the chat surface while the " +
      "picker is closed"
  );
});

test("only the open state turns the picker back on", () => {
  const open = rules().filter((r) =>
    /^\.reaction-picker\[data-open="true"\]$/.test(r.selector)
  );
  assert.equal(open.length, 1, "expected one `.reaction-picker[data-open=\"true\"]` rule");
  assert.equal(displayOf(open[0].body), "flex");
});

// A `display` on the panel would reintroduce the same hazard one level down:
// the panel is inside the container, so it inherits the gate — but only while
// the gate is on the container. Nothing else in this component may carry an
// unconditional `display` that could resurrect a closed picker.
test("no other reaction-picker selector re-enables display on the closed state", () => {
  const offenders = rules().filter(
    (r) =>
      r.selector.startsWith(".reaction-picker") &&
      !/\[data-open/.test(r.selector) &&
      r.selector !== ".reaction-picker" &&
      /^\.reaction-picker(\s|:|,|$)/.test(r.selector) &&
      displayOf(r.body) !== null
  );
  assert.deepEqual(
    offenders.map((r) => r.selector),
    [],
    "these selectors set `display` on the container outside the open state"
  );
});

// ── The two-interface split (desktop modal vs mobile sheet) ────────────────
//
// Desktop and mobile are two interfaces here, not one layout at two widths.
// These pin the parts of that split that are expressible in CSS.

test("desktop packs exactly 8 columns, not auto-fit's nine", () => {
  const desktop = rules().filter(
    (r) => r.selector === ".reaction-picker-grid" && /repeat\(8,/.test(r.body)
  );
  assert.equal(
    desktop.length,
    1,
    "`auto-fit, minmax(36px, 1fr)` packs NINE columns into the 400px desktop " +
      "panel. The design specifies eight, so the >=640px block must name the " +
      "count explicitly."
  );
});

test("the coarse-pointer block stays LAST, so touch wins on a tablet", () => {
  const desktopIdx = CSS.indexOf("@media (min-width: 640px)", CSS.indexOf(".reaction-picker {"));
  const coarseIdx = CSS.indexOf(
    "@media (hover: none) and (pointer: coarse)",
    CSS.indexOf(".reaction-picker {")
  );
  assert.ok(desktopIdx > 0 && coarseIdx > 0, "both picker media blocks must exist");
  assert.ok(
    coarseIdx > desktopIdx,
    "the coarse-pointer block must come after the min-width:640px block — both " +
      "match on a tablet and touch has to win, because it is what packs six " +
      "48px columns into the 375px sheet"
  );
});

test("no max-width: 639px block was added", () => {
  // The stylesheet is mobile-first: the bare rules ARE the mobile sheet and the
  // 640px block overrides into a desktop card. A `max-width: 639px` block would
  // be a second, competing expression of the same breakpoint.
  assert.equal(CSS.includes("max-width: 639px"), false);
});

test("the scroll container moved off the panel and onto the grid's area", () => {
  const panel = rules().find((r) => r.selector === ".reaction-picker-panel");
  assert.ok(panel, "no `.reaction-picker-panel` rule");
  assert.equal(
    /overflow-y\s*:/.test(panel.body),
    false,
    "the panel must not scroll: the sticky category headers, and stage 4's " +
      "pinned search field, scroll away with the content if it does"
  );

  const scroll = rules().find((r) => r.selector === ".reaction-picker-scroll");
  assert.ok(scroll, "no `.reaction-picker-scroll` rule");
  assert.match(scroll.body, /overflow-y\s*:\s*auto/);
  assert.match(scroll.body, /overscroll-behavior\s*:\s*contain/);
});

test("the tile focus ring is an inset shadow, never an outline", () => {
  const ring = rules().find((r) => r.selector === ".reaction-picker-tile:focus-visible");
  assert.ok(ring, "no focus-visible rule on `.reaction-picker-tile`");
  // An outline on a first- or last-column tile is clipped by the scroll
  // container's overflow, so the one element that has to be unmistakable would
  // be drawn half-missing.
  assert.match(ring.body, /box-shadow\s*:\s*inset/);
  assert.match(ring.body, /outline\s*:\s*none/);
});

// `success`, `warning` and `error` carry specific meanings elsewhere in the
// product. Nothing in this picker succeeds, fails, warns or informs, and
// spending a semantic slot here devalues it where it matters.
test("no semantic colour anywhere in the picker", () => {
  const banned = /--color-(success|warning|error|info)/;
  const offenders = rules().filter(
    (r) => r.selector.includes(".reaction-picker") && banned.test(r.body)
  );
  assert.deepEqual(offenders.map((r) => r.selector), []);
});

// ── Stage 4: search, the swapping row, and the palette corrections ─────────
//
// Task 019e0814 stage 4. These pin the parts of the search interface whose
// failure mode is invisible in a screenshot review.

// THE iOS AUTO-ZOOM TRAP. Any input under 16px triggers Safari's zoom-on-focus,
// and root.html.heex locks `maximum-scale=1`, so the user is left zoomed with
// no way to pinch back out. The fix is the one app.css already applies to the
// composer: 15px on a fine pointer, exactly 16px wherever hover is unavailable.
test("the search input is 15px, and exactly 16px where there is no hover", () => {
  const base = rules().find((r) => r.selector === ".reaction-picker-search-input");
  assert.ok(base, "no `.reaction-picker-search-input` rule");
  assert.match(base.body, /font-size\s*:\s*15px/);

  const touch = rules().filter(
    (r) => r.selector === ".reaction-picker-search-input" && /font-size\s*:\s*16px/.test(r.body)
  );
  assert.equal(
    touch.length,
    1,
    "expected exactly one `.reaction-picker-search-input` rule setting 16px — the " +
      "`@media (hover: none)` mitigation. Anything under 16px auto-zooms on iOS " +
      "Safari and `maximum-scale=1` means the user cannot pinch back out."
  );

  const idx = CSS.indexOf("@media (hover: none) {", CSS.indexOf(".reaction-picker {"));
  assert.ok(idx > 0, "the 16px rule must live in a bare `@media (hover: none)` block");
});

// THE ROW SWAPS CONTENTS, NOT SIZE. A row that changes height on the first
// keystroke moves the entire grid under the user mid-word.
test("the mode bar's height is fixed, so the swap cannot move the grid", () => {
  const bar = rules().find((r) => r.selector === ".reaction-picker-modebar");
  assert.ok(bar, "no `.reaction-picker-modebar` rule");
  assert.match(bar.body, /height\s*:\s*2rem/);
  assert.match(bar.body, /min-height\s*:\s*2rem/);
});

// `hidden` is how mode switching hides the four elements that carry their own
// `display`. The UA's `[hidden]` rule is a bare type selector and loses to any
// class, so without this the jump bar and the count would both be visible at
// once.
test("hidden beats the component's own display", () => {
  const guard = rules().find((r) => r.selector === ".reaction-picker-body [hidden]");
  assert.ok(guard, "no `[hidden]` guard scoped to the picker body");
  assert.match(guard.body, /display\s*:\s*none\s*!important/);
});

// THE PALETTE RULE THAT BREAKS ON DAY ONE. `--color-primary` serves two
// elements here — the focus ring and the active category chip — and they
// collide the moment a keyboard user tabs into the grid while the bar shows.
test("the focus ring outranks the active category chip", () => {
  const demote = rules().find((r) =>
    /^\.reaction-picker-panel:has\(:focus-visible\)/.test(r.selector)
  );
  assert.ok(
    demote,
    "no rule demoting the active chip while something in the panel shows a focus ring"
  );
  assert.match(demote.selector, /\.reaction-picker-chip\[aria-current="true"\]/);
  assert.equal(
    /--color-primary/.test(demote.body),
    false,
    "the demoted chip must give up --color-primary entirely — the whole point is " +
      "that only one thing on the surface glows at a time"
  );
});

// THE DARK LADDER IS NOT MONOTONIC. Dark `--color-base-200` is oklch(9%),
// thirteen lightness points BELOW the #171b25 panel, where light base-200 is
// four points above white's base-100. A "one subtle step up" written as
// base-200 is therefore a near-black band in dark and was exactly that in stage
// 3. Corrected to a translucent tint of the FOREGROUND composited over the
// panel, which is a consistent relative lift in both themes.
test("no picker surface uses base-200 as a subtle step up from the panel", () => {
  const offenders = rules().filter(
    (r) =>
      /^\.reaction-picker/.test(r.selector) &&
      /background-color\s*:\s*var\(--color-base-200\)/.test(r.body)
  );
  assert.deepEqual(
    offenders.map((r) => r.selector),
    [],
    "these use --color-base-200 as a ground. In dark it renders BELOW the panel " +
      "it sits on. Use var(--reaction-picker-tint)."
  );
});

// Ten-pixel text owes 4.5:1 and gets no large-text allowance. Dark
// --color-neutral measures 1.86:1 against the #171b25 panel, so every 10px
// label in this picker went through a component-layer correction. Using the
// raw token again would silently reintroduce it.
test("the small structural labels go through the corrected component token", () => {
  const small = [
    ".reaction-picker-category",
    ".reaction-picker-chip",
    ".reaction-picker-count",
  ];
  for (const selector of small) {
    const rule = rules().find((r) => r.selector === selector);
    assert.ok(rule, `no \`${selector}\` rule`);
    assert.match(
      rule.body,
      /color\s*:\s*var\(--reaction-picker-label\)/,
      `${selector} must use --reaction-picker-label; raw --color-neutral is 1.86:1 in dark`
    );
  }

  const offenders = rules().filter(
    (r) => /^\.reaction-picker/.test(r.selector) && /[^-]color\s*:\s*var\(--color-neutral\)/.test(r.body)
  );
  assert.deepEqual(offenders.map((r) => r.selector), []);
});

// THE PANEL IS A FIXED HEIGHT, NOT A MAXIMUM. Stage 4 gave it two short
// contents — a ranked result list and a one-line empty state — and a panel that
// sizes to its content resizes on the first keystroke. Measured at 1280px: the
// centred modal went 630px to 490px on typing "heart" and moved the search
// field 130px down under the cursor. Both the sheet rule and the ≥640px rule
// must pin `height`, or that returns.
test("the panel's height is fixed so typing cannot resize it", () => {
  const panels = rules().filter((r) => r.selector === ".reaction-picker-panel");
  const withHeight = panels.filter((r) => /(?:^|;)\s*height\s*:/.test(r.body));
  assert.equal(
    withHeight.length,
    2,
    "expected both the mobile sheet and the >=640px modal to pin `height` — a " +
      "`max-height` alone lets the panel size to its content and jump between " +
      "the inventory, a short result list and the empty state"
  );
  for (const rule of withHeight) {
    assert.match(rule.body, /height\s*:\s*min\(/);
    assert.match(rule.body, /--reaction-picker-kb/);
  }
});
