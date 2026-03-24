/**
 * ResizableSidebar — LiveView hook for drag-resizable chat sidebar.
 *
 * Attach to the <aside> element with phx-hook="ResizableSidebar".
 * Expects a child div.cursor-col-resize as the drag handle.
 *
 * Width persists in localStorage under "suite:sidebar_width".
 * Clamp range: 160px–480px. Default: 208px (≈ w-52).
 */

const STORAGE_KEY = "suite:sidebar_width"
const MIN_WIDTH = 160
const MAX_WIDTH = 480
const DEFAULT_WIDTH = 208

const ResizableSidebar = {
  mounted() {
    const saved = parseInt(localStorage.getItem(STORAGE_KEY), 10)
    this.el.style.width = `${saved >= MIN_WIDTH && saved <= MAX_WIDTH ? saved : DEFAULT_WIDTH}px`

    this._handle = this.el.querySelector(".cursor-col-resize")
    if (!this._handle) return

    this._onMouseDown = (e) => {
      e.preventDefault()
      const startX = e.clientX
      const startWidth = this.el.getBoundingClientRect().width

      document.body.classList.add("sidebar-resizing")

      const onMouseMove = (e) => {
        const newWidth = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, startWidth + (e.clientX - startX)))
        this.el.style.width = `${newWidth}px`
      }

      const onMouseUp = () => {
        document.removeEventListener("mousemove", onMouseMove)
        document.removeEventListener("mouseup", onMouseUp)
        document.body.classList.remove("sidebar-resizing")
        const finalWidth = Math.round(this.el.getBoundingClientRect().width)
        localStorage.setItem(STORAGE_KEY, String(finalWidth))
      }

      document.addEventListener("mousemove", onMouseMove)
      document.addEventListener("mouseup", onMouseUp)
    }

    this._handle.addEventListener("mousedown", this._onMouseDown)
  },

  destroyed() {
    if (this._handle && this._onMouseDown) {
      this._handle.removeEventListener("mousedown", this._onMouseDown)
    }
  },
}

export default ResizableSidebar
