const BrowserScope = {
  mounted() { this._highlight() },
  updated() { this._highlight() },
  destroyed() { clearTimeout(this._ringTimer) },
  _highlight() {
    const id = this.el.dataset.highlight
    if (id === this._highlighted) return
    clearTimeout(this._ringTimer)
    this.el.querySelectorAll(".browser-source-ring").forEach(el => el.classList.remove("browser-source-ring"))
    this._highlighted = id
    if (!id) return
    const row = Array.from(this.el.querySelectorAll("[data-item-id]")).find(el => el.dataset.itemId === id && el.dataset.kind === "canvas")
    if (!row) { this._highlighted = null; return }
    row.scrollIntoView({block: "nearest", behavior: "instant"})
    row.classList.add("browser-source-ring")
    this._ringTimer = setTimeout(() => row.classList.remove("browser-source-ring"), 1500)
  },
}
export default BrowserScope
