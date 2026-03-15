/**
 * SwipeDrawer — touch gesture hook for the mobile shell drawer.
 *
 * - Swipe left on the sidebar to close it.
 * - Swipe right from the left 20px edge to open it.
 */
const EDGE_ZONE = 20 // px from left edge to trigger open
const SWIPE_THRESHOLD = 60 // min px travel to count as swipe

const SwipeDrawer = {
  mounted() {
    this._onTouchStart = this._onTouchStart.bind(this)
    this._onTouchEnd = this._onTouchEnd.bind(this)

    // Listen on the sidebar itself for close swipes
    this.el.addEventListener("touchstart", this._onTouchStart, { passive: true })
    this.el.addEventListener("touchend", this._onTouchEnd, { passive: true })

    // Listen on document for edge-swipe open
    document.addEventListener("touchstart", this._onDocTouchStart = (e) => {
      const touch = e.touches[0]
      if (touch.clientX <= EDGE_ZONE) {
        this._edgeStart = { x: touch.clientX, y: touch.clientY }
      }
    }, { passive: true })

    document.addEventListener("touchend", this._onDocTouchEnd = (e) => {
      if (!this._edgeStart) return
      const touch = e.changedTouches[0]
      const dx = touch.clientX - this._edgeStart.x
      const dy = Math.abs(touch.clientY - this._edgeStart.y)
      this._edgeStart = null
      if (dx > SWIPE_THRESHOLD && dx > dy) {
        this.pushEvent("toggle_drawer", {})
      }
    }, { passive: true })
  },

  _onTouchStart(e) {
    const touch = e.touches[0]
    this._start = { x: touch.clientX, y: touch.clientY }
  },

  _onTouchEnd(e) {
    if (!this._start) return
    const touch = e.changedTouches[0]
    const dx = touch.clientX - this._start.x
    const dy = Math.abs(touch.clientY - this._start.y)
    this._start = null
    // Swipe left to close
    if (dx < -SWIPE_THRESHOLD && Math.abs(dx) > dy) {
      this.pushEvent("close_drawer", {})
    }
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this._onTouchStart)
    this.el.removeEventListener("touchend", this._onTouchEnd)
    document.removeEventListener("touchstart", this._onDocTouchStart)
    document.removeEventListener("touchend", this._onDocTouchEnd)
  }
}

export default SwipeDrawer
