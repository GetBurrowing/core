import RowLongPress, {longPressPayload} from "./row_long_press"

// Share the exact hold/scroll/release contract with chat and inbox rows.
const BrowserRow = {
  ...RowLongPress,
  mounted() {
    RowLongPress.mounted.call(this)
    this.el.removeEventListener("contextmenu", this._onContextMenu)
    this._onContextMenu = e => {
      if (this._editing()) return
      e.preventDefault()
      this._cancel()
      this.pushEvent(this.el.dataset.longPressEvent, longPressPayload(this.el.dataset))
    }
    this.el.addEventListener("contextmenu", this._onContextMenu)
    this._onKey = e => {
      if (e.key === "ContextMenu" || (e.shiftKey && e.key === "F10")) this._onContextMenu(e)
    }
    this.el.addEventListener("keydown", this._onKey)
    for (const [event, key] of [["touchstart", "_onTouchStart"], ["pointerdown", "_onPointerDown"]]) {
      const original = this[key]
      this.el.removeEventListener(event, original)
      this[key] = e => {
        if (e.target.closest("button,input,textarea,form")) return
        original(e)
      }
      this.el.addEventListener(event, this[key], {passive: true})
    }
  },
  destroyed() {
    this.el.removeEventListener("keydown", this._onKey)
    RowLongPress.destroyed.call(this)
  },
}
export default BrowserRow
