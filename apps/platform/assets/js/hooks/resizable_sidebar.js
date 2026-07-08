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

import ClientState from "../client_state.js";

const NAMESPACE = "sidebar";
const KEY = "width";
const LEGACY_KEY = "suite:sidebar_width:v2";
const DEFAULT_WIDTH = 224;

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

const ResizableSidebar = {
  mounted() {
    this.applyWidth();

    this._handle = this.el.querySelector("[data-drag-handle]");
    if (!this._handle) return;

    this._onMouseDown = (e) => {
      e.preventDefault();
      this._startX = e.clientX;
      this._startWidth = this.el.offsetWidth;
      document.body.classList.add("sidebar-resizing");
      document.addEventListener("mousemove", this._onMouseMove);
      document.addEventListener("mouseup", this._onMouseUp);
    };

    this._onMouseMove = (e) => {
      const delta = e.clientX - this._startX;
      const newWidth = Math.min(480, Math.max(160, this._startWidth + delta));
      this.el.style.width = newWidth + "px";
    };

    this._onMouseUp = () => {
      document.body.classList.remove("sidebar-resizing");
      document.removeEventListener("mousemove", this._onMouseMove);
      document.removeEventListener("mouseup", this._onMouseUp);
      ClientState.set(NAMESPACE, KEY, parseInt(this.el.style.width, 10));
    };

    this._handle.addEventListener("mousedown", this._onMouseDown);
  },

  // LiveView patches the aside element on diff-update and morphdom resets
  // inline styles set during mount. Re-apply the width on every update so
  // the rail stays at the configured size across LV re-renders.
  updated() {
    this.applyWidth();
  },

  applyWidth() {
    this.el.style.width = currentWidth() + "px";
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
