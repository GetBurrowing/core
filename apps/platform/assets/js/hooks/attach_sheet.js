// AttachSheet — the composer's ＋ menu pickers and the phone sheet's numbered
// library strip (redesign rung 11, task 01a1557a-9de3).
//
// Mounted on `#attach-strip` (a `phx-update="ignore"` container in the
// phone sheet, which also holds the hidden file inputs). It serves the
// desktop popover too: every `[data-attach-pick="<kind>"]` button anywhere on
// the page clicks `#attach-input-<kind>` inside the tap, so iOS keeps the
// user gesture and opens the native picker.
//
//   * library (sheet only): picked files join the strip PRE-SELECTED and
//     numbered in pick order; tapping a tile toggles it and renumbers. The
//     selection is client-only: nothing uploads until 'Attach N items',
//     which hands the selected Files to `stageFiles` in pick order.
//   * camera / audio / video / file / media: the pick stages straight into
//     the tray and the menu closes.
//
// Reopening the sheet starts empty; closing it revokes every object URL.

import { stageFiles } from "../attach_stage"

export function attachLabel(n) {
  return n === 1 ? "Attach 1 item" : `Attach ${n} items`
}

// The selection model, separate from the DOM so it can be tested alone.
// `picks` is every file in the strip, in pick order; `order` is the
// selected picks' ids in tap order (badge n = index + 1).
export function createSelection() {
  let nextId = 1
  const picks = []
  let order = []
  return {
    add(file, url) {
      const id = nextId++
      picks.push({ id, file, url })
      order.push(id)
      return id
    },
    toggle(id) {
      if (order.includes(id)) order = order.filter((x) => x !== id)
      else order.push(id)
    },
    number(id) {
      const i = order.indexOf(id)
      return i === -1 ? 0 : i + 1
    },
    picks() {
      return picks.slice()
    },
    selectedFiles() {
      return order.map((id) => picks.find((p) => p.id === id).file)
    },
    count() {
      return order.length
    },
    clear() {
      const urls = picks.map((p) => p.url).filter(Boolean)
      picks.length = 0
      order = []
      return urls
    },
  }
}

const TILE_CLASS =
  "relative size-24 shrink-0 overflow-hidden rounded-box border-2 bg-base-300 focus-visible-ring"
const BADGE_ON =
  "absolute right-1 top-1 flex size-[22px] items-center justify-center rounded-full bg-base-content text-xs font-bold tabular-nums text-base-100"
const BADGE_OFF =
  "absolute right-1 top-1 size-[22px] rounded-full border-2 border-white bg-black/30"

const AttachSheet = {
  mounted() {
    this._sel = createSelection()
    this._createUrl = (f) => (window.URL && URL.createObjectURL ? URL.createObjectURL(f) : "")
    this._revokeUrl = (u) => window.URL && URL.revokeObjectURL && URL.revokeObjectURL(u)

    this._onPickClick = (e) => {
      const btn = e.target instanceof Element ? e.target.closest("[data-attach-pick]") : null
      if (!btn) return
      const input = document.getElementById(`attach-input-${btn.getAttribute("data-attach-pick")}`)
      if (!input) return
      e.preventDefault()
      input.value = ""
      input.click()
    }
    document.addEventListener("click", this._onPickClick)

    this._onInputChange = (e) => {
      const input = e.target
      const kind = input && input.getAttribute && input.getAttribute("data-attach-input")
      if (!kind) return
      const files = Array.from(input.files || [])
      input.value = ""
      if (files.length === 0) return
      if (kind === "library") {
        for (const f of files) this._sel.add(f, this._createUrl(f))
        this.render()
      } else {
        stageFiles(this, files)
        this.pushEvent("attach_menu_close", {})
      }
    }
    this.el.addEventListener("change", this._onInputChange)

    this._onStripClick = (e) => {
      const tile = e.target instanceof Element ? e.target.closest("[data-pick-id]") : null
      if (!tile) return
      this._sel.toggle(Number(tile.getAttribute("data-pick-id")))
      this.render()
    }
    this.el.addEventListener("click", this._onStripClick)

    this._go = () => document.getElementById("attach-go")
    this._goWrap = () => document.getElementById("attach-go-wrap")
    this._onGo = (e) => {
      if (!(e.target instanceof Element) || !e.target.closest("#attach-go")) return
      const files = this._sel.selectedFiles()
      if (files.length === 0) return
      stageFiles(this, files)
      this.pushEvent("attach_menu_close", {})
    }
    document.addEventListener("click", this._onGo)

    // Reset whenever the sheet closes, however it closed.
    const sheet = document.getElementById("attach-sheet")
    if (sheet && typeof MutationObserver !== "undefined") {
      this._observer = new MutationObserver(() => {
        if (sheet.getAttribute("data-open") !== "true") this.reset()
      })
      this._observer.observe(sheet, { attributes: true, attributeFilter: ["data-open"] })
    }
    this.render()
  },

  destroyed() {
    document.removeEventListener("click", this._onPickClick)
    document.removeEventListener("click", this._onGo)
    if (this._observer) this._observer.disconnect()
    this.reset()
  },

  reset() {
    if (!this._sel) return
    for (const url of this._sel.clear()) this._revokeUrl(url)
    this.render()
  },

  render() {
    for (const old of this.el.querySelectorAll("[data-pick-id]")) old.remove()
    const anchor = this.el.querySelector("[data-attach-input]")
    for (const p of this._sel.picks()) {
      const n = this._sel.number(p.id)
      const tile = document.createElement("button")
      tile.type = "button"
      tile.setAttribute("data-pick-id", String(p.id))
      tile.setAttribute("role", "checkbox")
      tile.setAttribute("aria-checked", n > 0 ? "true" : "false")
      tile.setAttribute("aria-label", n > 0 ? `${p.file.name}, selected ${n}` : p.file.name)
      tile.className = `${TILE_CLASS} ${n > 0 ? "border-base-content" : "border-transparent"}`
      if (p.url && String(p.file.type || "").startsWith("image/")) {
        const img = document.createElement("img")
        img.src = p.url
        img.alt = ""
        img.className = "size-full object-cover"
        tile.appendChild(img)
      } else {
        const name = document.createElement("span")
        name.className = "absolute inset-x-1 bottom-1 truncate text-xs text-base-content"
        name.textContent = p.file.name
        tile.appendChild(name)
      }
      const badge = document.createElement("span")
      badge.setAttribute("aria-hidden", "true")
      badge.className = n > 0 ? BADGE_ON : BADGE_OFF
      if (n > 0) badge.textContent = String(n)
      tile.appendChild(badge)
      this.el.insertBefore(tile, anchor)
    }
    const count = this._sel.count()
    const wrap = this._goWrap()
    const go = this._go()
    if (wrap) wrap.hidden = count === 0
    if (go) go.textContent = attachLabel(count)
  },
}

export default AttachSheet
