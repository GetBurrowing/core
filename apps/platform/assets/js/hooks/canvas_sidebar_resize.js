// CanvasSidebarResize — desktop-only drag-resize for the pinned-canvas panel
// in ChatLive (`apps/platform/lib/platform_web/live/chat/partials.ex`
// `canvas_overlay/1`, desktop `hidden lg:flex` branch).
//
// This hook mirrors the shape of `resizable_sidebar.js` (left channel rail
// handle) with three deliberate deviations:
//
//   1. Left-edge handle → inverted delta. The channel rail sits on the LEFT
//      of the chat surface with its drag handle on its RIGHT edge; widening
//      moves the pointer RIGHT (`delta = e.clientX - startX`). The canvas
//      panel sits on the RIGHT of the chat surface with its drag handle on
//      its LEFT edge; widening moves the pointer LEFT
//      (`delta = startX - e.clientX`). Same additive formula, opposite sign.
//
//   2. Mobile self-guard. `phx-hook` mounts on `display:none` elements too,
//      so a hook attached to a `hidden lg:flex` panel will still fire
//      `mounted()` at 375px viewport. Below the `lg` breakpoint we bail
//      before touching pointer listeners, inline styles, or persistent
//      state so the mobile overlay branch of `canvas_overlay/1` stays
//      untouched. A `matchMedia` change listener re-runs mount/teardown
//      when the viewport crosses the boundary while the tab is open.
//
//   3. Bounds. Min 360px (canvas_document markdown / code-block readability
//      floor per Saru's design brief), max floor(innerWidth / 2) so the
//      chat main pane always keeps at least half the viewport, default
//      384px matching the current Tailwind `w-96` fallback.
//
// Storage flows through `Suite.ClientState` under namespace `canvas_sidebar`,
// key `width` — resulting full storage key `suite:canvas_sidebar:width`.
// Direct localStorage access is lint-gated across `assets/js/` (see
// `scripts/check_no_direct_localstorage.mjs`); the wrapper handles
// quota / security-error fallback into an in-memory map for private-mode
// Safari tabs.
//
// Keyboard nudges (stage 4):
//   - ArrowLeft / ArrowRight  → ±2px (LEFT edge handle: Left grows panel)
//   - Shift+ArrowLeft / Shift+ArrowRight → ±20px (coarse)
//   - Home  → jump to MAX
//   - End   → jump to MIN
//   - dblclick → reset to DEFAULT (384)
// Every keyboard interaction calls `event.preventDefault()` so the page
// doesn't scroll under the resize; every keyboard/mouse update refreshes
// `aria-valuenow` on the handle so SR users hear live width changes.
//
// The `.sidebar-resizing` body class + `app.css:448-451` cursor+select rules
// are reused verbatim from the channel-rail handle — no new CSS.

import ClientState from "../client_state.js";

const NAMESPACE = "canvas_sidebar";
const KEY = "width";
const MIN_WIDTH = 360;
const DEFAULT_WIDTH = 384;
const KEYBOARD_STEP = 2;
const KEYBOARD_STEP_COARSE = 20;
const DESKTOP_QUERY = "(min-width: 1024px)";

// Pure clamp — exported so the vitest suite can exercise the bounds math
// without spinning up a full mock DOM. Same discipline as
// `message_editor.js` exporting `shortenedOrRemoved`.
export function clampWidth(startWidth, delta, innerWidth) {
  const max = Math.floor(innerWidth * 0.5);
  const candidate = startWidth + delta;
  if (candidate < MIN_WIDTH) return MIN_WIDTH;
  if (candidate > max) return max;
  return candidate;
}

function maxWidth(innerWidth) {
  return Math.floor(innerWidth * 0.5);
}

function storedWidth() {
  const stored = ClientState.get(NAMESPACE, KEY, null);
  if (stored == null) return DEFAULT_WIDTH;
  const width = typeof stored === "number" ? stored : parseInt(stored, 10);
  return Number.isNaN(width) ? DEFAULT_WIDTH : width;
}

function isDesktop() {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia(DESKTOP_QUERY).matches
  );
}

const CanvasSidebarResize = {
  mounted() {
    // Install the matchMedia change listener regardless of the current
    // viewport so a resize from mobile → desktop (or the reverse) still
    // wires / tears down the drag machinery correctly.
    this._installMediaListener();

    // Mobile branch of `canvas_overlay/1` renders as a fullscreen fixed
    // overlay; the desktop panel this hook is attached to is `display:none`
    // below `lg`. `phx-hook` still mounts on hidden elements, so we bail
    // before touching state.
    if (!isDesktop()) return;

    this._activate();
  },

  destroyed() {
    this._removeMediaListener();
    this._deactivate();
  },

  // --- private -------------------------------------------------------------

  _activate() {
    if (this._active) return;
    this._active = true;

    const currentWidth = storedWidth();
    this.el.style.width = currentWidth + "px";

    this._handle = this.el.querySelector("[data-drag-handle]");
    if (!this._handle) return;

    this._writeAria(currentWidth);

    this._onMouseDown = (e) => {
      e.preventDefault();
      this._startX = e.clientX;
      this._startWidth = this.el.offsetWidth || parseInt(this.el.style.width, 10) || DEFAULT_WIDTH;
      document.body.classList.add("sidebar-resizing");
      document.addEventListener("mousemove", this._onMouseMove);
      document.addEventListener("mouseup", this._onMouseUp);
    };

    // Inverted delta: pointer moving LEFT widens the LEFT-edge-handled panel.
    this._onMouseMove = (e) => {
      const delta = this._startX - e.clientX;
      const newWidth = clampWidth(this._startWidth, delta, window.innerWidth);
      this.el.style.width = newWidth + "px";
      this._handle.setAttribute("aria-valuenow", String(newWidth));
    };

    this._onMouseUp = () => {
      document.body.classList.remove("sidebar-resizing");
      document.removeEventListener("mousemove", this._onMouseMove);
      document.removeEventListener("mouseup", this._onMouseUp);
      const finalWidth = parseInt(this.el.style.width, 10);
      if (!Number.isNaN(finalWidth)) {
        ClientState.set(NAMESPACE, KEY, finalWidth);
      }
    };

    // Keyboard nudges — LEFT edge handle inverts arrow semantics: ArrowLeft
    // grows the panel (pushes the edge outward), ArrowRight shrinks it.
    this._onKeyDown = (e) => {
      const currentWidth =
        parseInt(this.el.style.width, 10) || this.el.offsetWidth || DEFAULT_WIDTH;
      let delta = 0;
      let jumpTo = null;
      switch (e.key) {
        case "ArrowLeft":
          delta = e.shiftKey ? KEYBOARD_STEP_COARSE : KEYBOARD_STEP;
          break;
        case "ArrowRight":
          delta = e.shiftKey ? -KEYBOARD_STEP_COARSE : -KEYBOARD_STEP;
          break;
        case "Home":
          jumpTo = maxWidth(window.innerWidth);
          break;
        case "End":
          jumpTo = MIN_WIDTH;
          break;
        default:
          return;
      }
      e.preventDefault();
      const newWidth =
        jumpTo != null
          ? clampWidth(jumpTo, 0, window.innerWidth)
          : clampWidth(currentWidth, delta, window.innerWidth);
      this.el.style.width = newWidth + "px";
      this._writeAria(newWidth);
      ClientState.set(NAMESPACE, KEY, newWidth);
    };

    // Double-click resets to the DEFAULT — cheap discoverability affordance
    // per Saru §4. No modifier, no confirmation; reversible by dragging.
    this._onDblClick = (e) => {
      e.preventDefault();
      this.el.style.width = DEFAULT_WIDTH + "px";
      this._writeAria(DEFAULT_WIDTH);
      ClientState.set(NAMESPACE, KEY, DEFAULT_WIDTH);
    };

    this._handle.addEventListener("mousedown", this._onMouseDown);
    this._handle.addEventListener("keydown", this._onKeyDown);
    this._handle.addEventListener("dblclick", this._onDblClick);
  },

  _deactivate() {
    if (!this._active) return;
    if (this._handle) {
      this._handle.removeEventListener("mousedown", this._onMouseDown);
      this._handle.removeEventListener("keydown", this._onKeyDown);
      this._handle.removeEventListener("dblclick", this._onDblClick);
    }
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
    document.body.classList.remove("sidebar-resizing");
    this._active = false;
  },

  _writeAria(width) {
    if (!this._handle) return;
    this._handle.setAttribute("aria-valuemin", String(MIN_WIDTH));
    this._handle.setAttribute("aria-valuemax", String(maxWidth(window.innerWidth)));
    this._handle.setAttribute("aria-valuenow", String(width));
  },

  _installMediaListener() {
    if (
      typeof window === "undefined" ||
      typeof window.matchMedia !== "function"
    ) {
      return;
    }
    this._mediaQuery = window.matchMedia(DESKTOP_QUERY);
    this._onMediaChange = (evt) => {
      if (evt.matches) {
        this._activate();
      } else {
        this._deactivate();
      }
    };
    if (typeof this._mediaQuery.addEventListener === "function") {
      this._mediaQuery.addEventListener("change", this._onMediaChange);
    } else if (typeof this._mediaQuery.addListener === "function") {
      // Safari <14 fallback.
      this._mediaQuery.addListener(this._onMediaChange);
    }
  },

  _removeMediaListener() {
    if (!this._mediaQuery || !this._onMediaChange) return;
    if (typeof this._mediaQuery.removeEventListener === "function") {
      this._mediaQuery.removeEventListener("change", this._onMediaChange);
    } else if (typeof this._mediaQuery.removeListener === "function") {
      this._mediaQuery.removeListener(this._onMediaChange);
    }
    this._mediaQuery = null;
    this._onMediaChange = null;
  },
};

export default CanvasSidebarResize;
