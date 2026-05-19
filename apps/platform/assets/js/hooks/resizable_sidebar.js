// Default width matches the expanded icon-rail (w-56 = 224px) so the channel
// rail visually aligns with the primary nav on first paint.
//
// Key is :v2 so any saved value from the previous (208px) default is ignored
// once — the next drag-resize re-pins under the new key.
const STORAGE_KEY = "suite:sidebar_width:v2";
const DEFAULT_WIDTH = 224;

function currentWidth() {
  const saved = localStorage.getItem(STORAGE_KEY);
  return saved ? parseInt(saved, 10) : DEFAULT_WIDTH;
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
      localStorage.setItem(STORAGE_KEY, parseInt(this.el.style.width, 10));
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
