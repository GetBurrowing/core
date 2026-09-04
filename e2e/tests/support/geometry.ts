// Geometry helpers for the meetings layout gate (task 01a064fa).
//
// WHY THIS FILE EXISTS. Three rounds of the meetings surface passed their
// e2e gates and were rejected on sight by the sponsor. Every element the
// approved canvas called for was PRESENT and every colour token was right —
// they were wired into the WRONG PARENTS. The gates that passed were
// presence checks, and a presence check passes perfectly on a screen that
// reads as a different design.
//
// So: nothing in this module matches on text or on class names. A
// `toHaveClass(/border-info/)` assertion is the SAME SPECIES of check as
// the presence check it would replace — it passes on a screen where the
// ring floats at the row's right edge beside a bare avatar, which is
// exactly the defect. Everything here resolves through
// `getBoundingClientRect()` and DOM ancestry (`Node.contains`,
// `Element.closest`, `compareDocumentPosition`).
//
// NO HELPER CARRIES A DEFAULT TOLERANCE. Every predicate takes its
// tolerance explicitly. A default is how one threshold gets loosened once
// and then silently governs four assertions.

import type { Page } from "@playwright/test";

/** A plain, structurally-cloneable rect. `DOMRect` does not survive
 *  `page.evaluate`'s serialization boundary as a class instance, so the
 *  helpers hand back this shape rather than pretending to return a real
 *  `DOMRect`. */
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
  top: number;
  right: number;
  bottom: number;
  left: number;
}

/** Thrown when a selector does not resolve to exactly one element.
 *  Ambiguity must fail LOUDLY: each control exists twice in the meetings
 *  DOM (a hidden `lg`-only copy and the mobile copy), so a silent
 *  `.first()` would measure a hidden element whose rect is all zeroes —
 *  and a zero rect passes every containment test there is. */
export class SelectorAmbiguityError extends Error {
  readonly selector: string;
  readonly matched: number;

  constructor(selector: string, matched: number, detail: string) {
    super(
      `geometry: selector ${JSON.stringify(selector)} matched ${matched} element(s) — ${detail}`,
    );
    this.name = "SelectorAmbiguityError";
    this.selector = selector;
    this.matched = matched;
  }
}

const RECT_IN_PAGE = (selector: string) => {
  const nodes = Array.from(document.querySelectorAll(selector));
  return nodes.map((n) => {
    const r = n.getBoundingClientRect();
    return {
      x: r.x,
      y: r.y,
      width: r.width,
      height: r.height,
      top: r.top,
      right: r.right,
      bottom: r.bottom,
      left: r.left,
    };
  });
};

/** Every match's rect, in document order. Exposed because the disambiguation
 *  in `visibleRect` is worth being able to SHOW: a run that reports the rects
 *  of both the hidden and the visible copy has demonstrated the
 *  disambiguation fired, where a bare pass has not. */
export async function allRects(page: Page, selector: string): Promise<Rect[]> {
  return (await page.evaluate(RECT_IN_PAGE, selector)) as Rect[];
}

/** The rect of the UNIQUE element matching `selector`.
 *  Throws `SelectorAmbiguityError` on zero or more than one match. */
export async function rect(page: Page, selector: string): Promise<Rect> {
  const rects = await allRects(page, selector);
  if (rects.length !== 1) {
    throw new SelectorAmbiguityError(
      selector,
      rects.length,
      rects.length === 0
        ? "expected exactly one; nothing matched"
        : `expected exactly one; use visibleRect() if the duplicates are a hidden lg-only copy. rects=${JSON.stringify(rects)}`,
    );
  }
  return rects[0];
}

/** The disambiguating variant: of all matches, the unique one with a
 *  non-zero bounding rect. Throws when zero or more than one qualifies.
 *  This is what the responsive surfaces need — both the desktop and the
 *  mobile copy of a control are in the document at all times and exactly
 *  one of them is laid out. */
export async function visibleRect(page: Page, selector: string): Promise<Rect> {
  const rects = await allRects(page, selector);
  const nonZero = rects.filter((r) => r.width > 0 && r.height > 0);
  if (nonZero.length !== 1) {
    throw new SelectorAmbiguityError(
      selector,
      nonZero.length,
      nonZero.length === 0
        ? `expected exactly one match with a non-zero rect; ${rects.length} matched the selector and all had a zero rect. rects=${JSON.stringify(rects)}`
        : `expected exactly one match with a non-zero rect. nonZeroRects=${JSON.stringify(nonZero)}`,
    );
  }
  return nonZero[0];
}

/** True when `ancestorSel`'s element strictly contains `descendantSel`'s.
 *  `a.contains(b)` is true when `a === b`, which would make "the face is
 *  inside the avatar wrapper" pass on a document where the two selectors
 *  landed on one element — so the identity case is excluded. Both
 *  selectors must resolve uniquely. */
export async function isAncestor(
  page: Page,
  ancestorSel: string,
  descendantSel: string,
): Promise<boolean> {
  return await page.evaluate(
    ({ ancestorSel, descendantSel }) => {
      const as = document.querySelectorAll(ancestorSel);
      const ds = document.querySelectorAll(descendantSel);
      if (as.length !== 1 || ds.length !== 1) {
        throw new Error(
          `geometry.isAncestor: expected exactly one match each, got ${as.length} for ${ancestorSel} and ${ds.length} for ${descendantSel}`,
        );
      }
      const a = as[0];
      const d = ds[0];
      return a.contains(d) && a !== d;
    },
    { ancestorSel, descendantSel },
  );
}

export type DomOrder = "before" | "after" | "unrelated";

/** Document order of A relative to B, via `compareDocumentPosition`.
 *  `'unrelated'` covers the disconnected case and the containment cases —
 *  an element that CONTAINS the other is not "before" it in the sense any
 *  caller here means, and collapsing that into `'before'` would let a
 *  nesting change pass an ordering assertion. */
export async function domOrder(
  page: Page,
  selA: string,
  selB: string,
): Promise<DomOrder> {
  return (await page.evaluate(
    ({ selA, selB }) => {
      const as = document.querySelectorAll(selA);
      const bs = document.querySelectorAll(selB);
      if (as.length !== 1 || bs.length !== 1) {
        throw new Error(
          `geometry.domOrder: expected exactly one match each, got ${as.length} for ${selA} and ${bs.length} for ${selB}`,
        );
      }
      const a = as[0];
      const b = bs[0];
      if (a === b) return "unrelated";
      const pos = a.compareDocumentPosition(b);
      if (pos & Node.DOCUMENT_POSITION_DISCONNECTED) return "unrelated";
      if (pos & Node.DOCUMENT_POSITION_CONTAINS) return "unrelated";
      if (pos & Node.DOCUMENT_POSITION_CONTAINED_BY) return "unrelated";
      if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return "before";
      if (pos & Node.DOCUMENT_POSITION_PRECEDING) return "after";
      return "unrelated";
    },
    { selA, selB },
  )) as DomOrder;
}

/** A's top is at or below B's bottom, allowing `tolerancePx` of overlap.
 *  Tolerance is REQUIRED — see the module header. */
export function isBelow(
  rectA: Rect,
  rectB: Rect,
  tolerancePx: number,
): boolean {
  requireTolerance(tolerancePx, "isBelow");
  return rectA.top >= rectB.bottom - tolerancePx;
}

/** The ratio test the grid assertion uses: the child spans the parent on
 *  BOTH axes, to within `tolerancePx` per axis. This is what fails on the
 *  measured v1 defect — two participants laid out at ~520px inside a ~745px
 *  stage with wide dead margins — and what a presence check cannot see. */
export function fillsContainer(
  childRect: Rect,
  parentRect: Rect,
  tolerancePx: number,
): boolean {
  requireTolerance(tolerancePx, "fillsContainer");
  return (
    parentRect.width - childRect.width <= tolerancePx &&
    parentRect.height - childRect.height <= tolerancePx
  );
}

/** Per-edge overflow of `childRect` outside `containerRect`, in px, each
 *  clamped at 0 when that edge is contained. All-zero means fully inside.
 *
 *  Takes no tolerance ON PURPOSE: it MEASURES rather than judging, and the
 *  caller applies its own threshold to the numbers. A tolerance here would
 *  be a threshold hidden inside a measurement. */
export function clippedBy(
  childRect: Rect,
  containerRect: Rect,
): { top: number; right: number; bottom: number; left: number } {
  return {
    top: Math.max(0, containerRect.top - childRect.top),
    right: Math.max(0, childRect.right - containerRect.right),
    bottom: Math.max(0, childRect.bottom - containerRect.bottom),
    left: Math.max(0, containerRect.left - childRect.left),
  };
}

function requireTolerance(tolerancePx: number, who: string): void {
  if (typeof tolerancePx !== "number" || !Number.isFinite(tolerancePx)) {
    throw new Error(
      `geometry.${who}: tolerancePx is required and must be a finite number (got ${String(tolerancePx)})`,
    );
  }
  if (tolerancePx < 0) {
    throw new Error(
      `geometry.${who}: tolerancePx must not be negative (got ${tolerancePx})`,
    );
  }
}
