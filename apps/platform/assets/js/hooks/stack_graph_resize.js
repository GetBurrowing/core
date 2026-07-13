// StackGraphResize — persists the user-picked size of the stack-detail
// dep-DAG container via Suite.ClientState so it survives navigations and
// reloads. Task 019f487e stages 2 & 3.
//
// Storage contract:
//   namespace: "tasks_ui"
//   key:       "stack_graph_size"
//   value:     { width: <number>, height: <number> }  // CSS pixels, BORDER-box
//
// Border-box invariant (stage 3 bug fix):
//   We persist `el.offsetWidth` / `el.offsetHeight` — Tailwind defaults every
//   element to `box-sizing: border-box`, and the restore path writes
//   `el.style.width = <stored>px`, which the browser interprets as border-box.
//   `ResizeObserver.contentRect` is the CONTENT box (padding-excluded); the
//   container carries `p-2` (8px each side, 16px total per axis). Storing the
//   contentRect value and restoring it as border-box shrunk the stored value
//   by 2×padding on every mount round-trip (baseline 784×584 → post-drag
//   1184×884 → after nav round-trip 1168×868, and so on). Using offsetWidth /
//   offsetHeight closes the loop — the stored number matches what
//   `style.width` reads back into on the next mount.
//   The SVG re-fit path deliberately keeps consuming `contentRect` because
//   that IS the internal drawable area the SVG should fill; those two
//   consumers want two different boxes.
//
// Touch resize (stage 3, mobile / coarse-pointer):
//   The `[data-role="stack-detail-dag-resize-handle"]` child button is the
//   custom handle rendered by tasks_live.html.heex. On `touchstart` we
//   snapshot the starting touch position and the container's border-box
//   dimensions, then attach global `touchmove` / `touchend` listeners on
//   `document` (a finger can leave the handle mid-drag and still resize —
//   the handle-scoped listener alone would drop the gesture). Delta is
//   applied to `el.style.width` / `el.style.height` clamped to
//   [260, window.innerWidth] × [240, window.innerHeight]. All three
//   listeners use `{passive: false}` because we `preventDefault()` to stop
//   the page scrolling under the finger. The single write path stays with
//   the ResizeObserver + 300ms debounce — the touch handler NEVER calls
//   `ClientState.set` directly, preserving the single-write-path invariant
//   and avoiding double writes.
//
// SVG intrinsic-sizing workaround (stage 3):
//   `w-full h-full` on the child `<svg>` inside an `overflow-auto`
//   resizable parent produces zero-height layout on WebKit iOS under
//   certain flex / grid ancestor conditions — the SVG's intrinsic aspect
//   ratio wins over the CSS. Belt-and-braces: on every ResizeObserver fire
//   (NOT debounced — this is a render concern, not persistence), we set
//   the SVG's inline `style.width` and `style.height` to the container's
//   contentRect minus an 8px handle reserve on the height so the corner
//   handle doesn't visually overlap the graph. This makes the fit
//   deterministic across browsers. DO NOT strip this even if it looks
//   redundant with `w-full h-full` — the underlying intrinsic-sizing quirk
//   resurfaces silently under overflow-auto + resize:both parents.
//
// Responsive defaults (used when nothing is stored, or when the stored
// value fails validation):
//   fine-pointer  (desktop): { width: dataset.desktopDefaultW  || 800,
//                              height: dataset.desktopDefaultH || 600 }
//   coarse-pointer (mobile): { width: parentElement.clientWidth,
//                              height: dataset.mobileDefaultH  || 420 }
//
// Validation floor / ceiling — reject-and-fallback on:
//   width  < 260  or  width  > window.innerWidth  * 2
//   height < 240  or  height > window.innerHeight * 2
//   non-finite or non-positive numbers, missing fields, non-object
//
// Persistence: ResizeObserver on `this.el` writes ClientState.set with a
// 300ms trailing debounce. Covers both the desktop native-corner drag and
// the mobile touch-driven path — one write channel for both.
//
// Lifecycle:
//   mounted()   — compute defaults, restore stored value if valid, apply
//                 to inline style, wire ResizeObserver + touch handlers.
//   updated()   — no-op. The container's `phx-update="ignore"` (stage 1)
//                 means LiveView never patches children of this element,
//                 so inline styles survive re-renders. Cleaner than
//                 resizable_sidebar's applyWidth() re-apply loop.
//   destroyed() — disconnect the ResizeObserver, clear pending debounce,
//                 remove the handle's touchstart listener, and defensively
//                 remove any global touchmove / touchend listeners still
//                 attached (users can navigate away mid-drag).

import ClientState from "../client_state.js";

const NAMESPACE = "tasks_ui";
const KEY = "stack_graph_size";
const DEBOUNCE_MS = 300;
const MIN_WIDTH = 260;
const MIN_HEIGHT = 240;
const DEFAULT_DESKTOP_W = 800;
const DEFAULT_DESKTOP_H = 600;
const DEFAULT_MOBILE_H = 420;
const HANDLE_RESERVE_PX = 8;
const SVG_SELECTOR = '[data-role="stack-detail-dag-svg"]';
const HANDLE_SELECTOR = '[data-role="stack-detail-dag-resize-handle"]';

function parseDatasetInt(value, fallback) {
  const parsed = parseInt(value, 10);
  return Number.isNaN(parsed) ? fallback : parsed;
}

function isCoarsePointer() {
  try {
    return !!(
      globalThis.matchMedia && globalThis.matchMedia("(pointer: coarse)").matches
    );
  } catch (_err) {
    return false;
  }
}

function computeDefaults(el) {
  if (isCoarsePointer()) {
    const parentWidth =
      (el.parentElement && el.parentElement.clientWidth) || DEFAULT_DESKTOP_W;
    return {
      width: parentWidth,
      height: parseDatasetInt(el.dataset.mobileDefaultH, DEFAULT_MOBILE_H),
    };
  }
  return {
    width: parseDatasetInt(el.dataset.desktopDefaultW, DEFAULT_DESKTOP_W),
    height: parseDatasetInt(el.dataset.desktopDefaultH, DEFAULT_DESKTOP_H),
  };
}

function validateStored(stored) {
  if (!stored || typeof stored !== "object" || Array.isArray(stored)) return null;
  const { width, height } = stored;
  if (typeof width !== "number" || typeof height !== "number") return null;
  if (!Number.isFinite(width) || !Number.isFinite(height)) return null;
  if (width <= 0 || height <= 0) return null;
  if (width < MIN_WIDTH || height < MIN_HEIGHT) return null;
  const wCeil = (globalThis.innerWidth || DEFAULT_DESKTOP_W) * 2;
  const hCeil = (globalThis.innerHeight || DEFAULT_DESKTOP_H) * 2;
  if (width > wCeil || height > hCeil) return null;
  return { width, height };
}

function applySize(el, size) {
  el.style.width = `${size.width}px`;
  el.style.height = `${size.height}px`;
}

const StackGraphResize = {
  mounted() {
    const defaults = computeDefaults(this.el);
    const stored = validateStored(ClientState.get(NAMESPACE, KEY, null));
    const initial = stored || defaults;
    applySize(this.el, initial);

    this._svg =
      typeof this.el.querySelector === "function"
        ? this.el.querySelector(SVG_SELECTOR)
        : null;

    this._pendingSize = null;
    this._debounceTimer = null;
    this._touching = false;
    this._touchStartX = 0;
    this._touchStartY = 0;
    this._touchStartW = 0;
    this._touchStartH = 0;

    const RO = globalThis.ResizeObserver;
    if (typeof RO === "function") {
      this._observer = new RO((entries) => {
        const entry = entries[entries.length - 1];
        if (!entry) return;

        // Render concern: re-fit the child SVG. NOT debounced — visual
        // must track the drag frame-by-frame. See file header for the
        // intrinsic-sizing workaround rationale.
        this._fitSvg(entry.contentRect);

        // Persistence: read border-box (offsetWidth / offsetHeight) so
        // the stored value round-trips with the style.width / style.height
        // restore path. See file header "border-box invariant".
        const width = this.el.offsetWidth;
        const height = this.el.offsetHeight;
        if (!Number.isFinite(width) || !Number.isFinite(height)) return;
        this._pendingSize = { width, height };
        if (this._debounceTimer != null) {
          clearTimeout(this._debounceTimer);
        }
        this._debounceTimer = setTimeout(() => {
          this._debounceTimer = null;
          const size = this._pendingSize;
          this._pendingSize = null;
          if (size) ClientState.set(NAMESPACE, KEY, size);
        }, DEBOUNCE_MS);
      });
      this._observer.observe(this.el);
    }

    // Touch resize wiring (mobile / coarse-pointer). Bind once so we can
    // symmetrically remove in destroyed().
    this._handle =
      typeof this.el.querySelector === "function"
        ? this.el.querySelector(HANDLE_SELECTOR)
        : null;

    if (this._handle) {
      this._onTouchStart = (e) => this._handleTouchStart(e);
      this._onTouchMove = (e) => this._handleTouchMove(e);
      this._onTouchEnd = (e) => this._handleTouchEnd(e);
      this._handle.addEventListener("touchstart", this._onTouchStart, {
        passive: false,
      });
    } else if (typeof console !== "undefined" && console && console.warn) {
      console.warn(
        "[StackGraphResize] no [data-role=stack-detail-dag-resize-handle] child — mobile touch resize disabled",
      );
    }
  },

  updated() {
    // Intentional no-op — see file header. `phx-update="ignore"` on the
    // container means LV never patches the subtree, so the inline styles
    // written by `mounted()` and the ResizeObserver survive re-renders.
  },

  destroyed() {
    if (this._observer) {
      try {
        this._observer.disconnect();
      } catch (_err) {
        // no-op
      }
      this._observer = null;
    }
    if (this._debounceTimer != null) {
      clearTimeout(this._debounceTimer);
      this._debounceTimer = null;
    }
    this._pendingSize = null;

    // Touch listener cleanup. Defensive: users can navigate away mid-drag
    // with global listeners still attached — remove regardless of the
    // `_touching` flag so nothing leaks past LV teardown.
    if (this._handle && this._onTouchStart) {
      try {
        this._handle.removeEventListener("touchstart", this._onTouchStart);
      } catch (_err) {
        // no-op
      }
    }
    const doc = globalThis.document;
    if (doc && this._onTouchMove) {
      try {
        doc.removeEventListener("touchmove", this._onTouchMove);
      } catch (_err) {
        // no-op
      }
    }
    if (doc && this._onTouchEnd) {
      try {
        doc.removeEventListener("touchend", this._onTouchEnd);
      } catch (_err) {
        // no-op
      }
    }
    this._touching = false;
    this._handle = null;
    this._svg = null;
    this._onTouchStart = null;
    this._onTouchMove = null;
    this._onTouchEnd = null;
  },

  _fitSvg(rect) {
    if (!this._svg || !rect || !this._svg.style) return;
    const width = Number.isFinite(rect.width) ? rect.width : 0;
    const height = Number.isFinite(rect.height) ? rect.height : 0;
    this._svg.style.width = `${width}px`;
    this._svg.style.height = `${Math.max(0, height - HANDLE_RESERVE_PX)}px`;
  },

  _handleTouchStart(e) {
    if (!e || !e.touches || e.touches.length === 0) return;
    if (typeof e.preventDefault === "function") e.preventDefault();
    const t = e.touches[0];
    this._touchStartX = t.clientX;
    this._touchStartY = t.clientY;
    this._touchStartW = this.el.offsetWidth || 0;
    this._touchStartH = this.el.offsetHeight || 0;
    this._touching = true;

    const doc = globalThis.document;
    if (!doc) return;
    doc.addEventListener("touchmove", this._onTouchMove, { passive: false });
    doc.addEventListener("touchend", this._onTouchEnd, { passive: false });
  },

  _handleTouchMove(e) {
    if (!this._touching || !e || !e.touches || e.touches.length === 0) return;
    if (typeof e.preventDefault === "function") e.preventDefault();
    const t = e.touches[0];
    const dx = t.clientX - this._touchStartX;
    const dy = t.clientY - this._touchStartY;
    const wCeil = globalThis.innerWidth || Number.POSITIVE_INFINITY;
    const hCeil = globalThis.innerHeight || Number.POSITIVE_INFINITY;
    const w = Math.max(MIN_WIDTH, Math.min(wCeil, this._touchStartW + dx));
    const h = Math.max(MIN_HEIGHT, Math.min(hCeil, this._touchStartH + dy));
    this.el.style.width = `${w}px`;
    this.el.style.height = `${h}px`;
  },

  _handleTouchEnd(_e) {
    this._touching = false;
    const doc = globalThis.document;
    if (!doc) return;
    try {
      doc.removeEventListener("touchmove", this._onTouchMove);
      doc.removeEventListener("touchend", this._onTouchEnd);
    } catch (_err) {
      // no-op
    }
  },
};

export default StackGraphResize;
