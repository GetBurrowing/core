// ResizableSidebar — persists the shell sidebar's user-picked width via
// Suite.ClientState so it survives navigations and reloads.
//
// Default width matches the expanded icon-rail (w-56 = 224px) so the channel
// rail visually aligns with the primary nav on first paint.
//
// Task 019f3e9a stage 3: migrated off ad-hoc direct-store calls onto
// `Suite.ClientState`. The legacy raw key `"suite:sidebar_width:v2"` is
// read once, migrated to the store, and deleted. The `:v2` suffix baked
// into the legacy key already discarded pre-224px values; the migrated
// entry preserves the user's latest drag-resized width.
//
// WHY A ROOT-LEVEL CSS VARIABLE, NOT `el.style.width` (task 01a05873).
// This hook previously set the width as an inline style on `#chat-sidebar`
// and re-applied it in `updated()` because — as the old comment on
// `updated()` already knew — "LiveView patches the aside element on
// diff-update and morphdom resets inline styles set during mount."
// That reset is not instantaneous bookkeeping: it leaves a WINDOW, from
// the moment morphdom strips the inline style to the moment `updated()`
// re-applies it, in which the aside has NO width constraint at all and
// (`flex-shrink-0`) renders at its intrinsic content width — 468px on a
// 1440px desktop instead of the configured 224px. Every patch that
// touches the sidebar (any arriving message re-renders the rail
// previews/unread counts) walks that window, and any hook that reads
// layout DURING the patch sees the chat column squeezed ~244px narrower
// with every message body rewrapped taller. `ScrollToBottom.beforeUpdate`
// is exactly such a reader — morphdom reaches the aside (earlier in
// document order) before `#message-list`, so its pre-patch distance
// capture measured the rewrap-inflated scrollHeight and poisoned BOTH the
// follow decision and the jump-chip predicate (one reading feeds both —
// task 01a0419a stage 4). The reported symptom was "desktop chat doesn't
// autoscroll to the latest message"; mobile never saw it because
// `#chat-sidebar` is `hidden lg:flex` and below `lg` the squeeze doesn't
// exist.
//
// Writing the width to a custom property on `document.documentElement`
// moves it OUT of any element LiveView ever patches, and the matching
// `#chat-sidebar { width: var(--suite-sidebar-width, 224px) }` rule in
// app.css carries the constraint in the stylesheet. The mid-patch window
// closes by construction: there is no inline style left to strip.

import ClientState from "../client_state.js";

const NAMESPACE = "sidebar";
const KEY = "width";
const LEGACY_KEY = "suite:sidebar_width:v2";
const DEFAULT_WIDTH = 224;
const WIDTH_VAR = "--suite-sidebar-width";

function currentWidth() {
  let stored = ClientState.get(NAMESPACE, KEY, null);
  if (stored === null) {
    // Legacy key migration — one-shot read-then-delete so we don't keep
    // paying the extra raw-store lookup on every LV update.
    try {
      const legacy = globalThis.localStorage?.getItem(LEGACY_KEY); // client-state:allow (legacy migration)
      if (legacy != null) {
        const parsed = parseInt(legacy, 10);
        if (!Number.isNaN(parsed)) {
          stored = parsed;
          ClientState.set(NAMESPACE, KEY, parsed);
        }
        globalThis.localStorage.removeItem(LEGACY_KEY); // client-state:allow (legacy migration)
      }
    } catch (_e) {
      // private mode / no localStorage; fall through to default.
    }
  }
  if (stored == null) return DEFAULT_WIDTH;
  const width = typeof stored === "number" ? stored : parseInt(stored, 10);
  return Number.isNaN(width) ? DEFAULT_WIDTH : width;
}

// The width lives on <html>, which LiveView never patches, so it survives
// every LV re-render without the mid-patch window an inline style has.
// `applyWidth`/drag both go through here; `this._width` is the hook's own
// record of the live value so mouseup never has to parse it back out of
// a style string.
function writeWidthVar(px) {
  document.documentElement.style.setProperty(WIDTH_VAR, px + "px");
}

const ResizableSidebar = {
  mounted() {
    this._width = currentWidth();
    writeWidthVar(this._width);

    this._handle = this.el.querySelector("[data-drag-handle]");
    if (!this._handle) return;

    this._onMouseDown = (e) => {
      e.preventDefault();
      this._startX = e.clientX;
      this._startWidth = this._width;
      document.body.classList.add("sidebar-resizing");
      document.addEventListener("mousemove", this._onMouseMove);
      document.addEventListener("mouseup", this._onMouseUp);
    };

    this._onMouseMove = (e) => {
      const delta = e.clientX - this._startX;
      this._width = Math.min(480, Math.max(160, this._startWidth + delta));
      writeWidthVar(this._width);
    };

    this._onMouseUp = () => {
      document.body.classList.remove("sidebar-resizing");
      document.removeEventListener("mousemove", this._onMouseMove);
      document.removeEventListener("mouseup", this._onMouseUp);
      ClientState.set(NAMESPACE, KEY, this._width);
    };

    this._handle.addEventListener("mousedown", this._onMouseDown);
  },

  // Re-apply on every LV update. With the width on the root variable this
  // is now a no-op unless something else cleared the variable between
  // patches (an explicit `html { --suite-sidebar-width: … }` edit in the
  // console, a different surface clearing it): it exists so the sidebar
  // can never drift from the stored preference, not because morphdom can
  // strip it — it cannot, there is no inline style left to strip.
  updated() {
    this._width = currentWidth();
    writeWidthVar(this._width);
  },

  destroyed() {
    if (this._handle) {
      this._handle.removeEventListener("mousedown", this._onMouseDown);
    }
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
    document.body.classList.remove("sidebar-resizing");
  },
};

export default ResizableSidebar;
