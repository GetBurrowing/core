/**
 * CommandPalette hook (Burrow redesign 23 stage 4; master-desktop.html
 * L1307-1312). Mounted on `#command-palette`, the root of the shell's one
 * `PlatformWeb.CommandPaletteLive`, never per LiveView.
 *
 * ONE document keydown listener, capture phase, shared by every mount (a
 * module-level guard; the last instance destroyed removes it):
 *
 *   - ⌘K / Ctrl+K (no Alt, no Shift, not composing) toggles the palette, but
 *     only at >= 1024px; below that the key is left alone entirely (no
 *     preventDefault). It is the one key handled inside an input, textarea
 *     or contenteditable such as the composer.
 *   - While the palette is closed, nothing else is touched.
 *   - While open (`data-open="true"`): Escape closes it and stops there
 *     (preventDefault + stopPropagation, so a sheet, popover or the details
 *     panel underneath never sees it); ArrowDown / ArrowUp move
 *     `aria-selected` over the `role=option` rows, wrapping at both ends;
 *     Enter pushes `palette_go {q, index}`.
 *
 * A click on the scrim (the root itself) closes. `updated()` resets the
 * selection to 0 when the rendered query (`data-query` on the listbox)
 * changes, focuses the input on open, and on close returns focus (and the
 * caret: a text control's selection range, or a contenteditable's document
 * selection) to the element that held it before the palette opened. Neither
 * focus move scrolls the page.
 */

export const DESKTOP_QUERY = "(min-width: 1024px)"

// Module-level guard: one listener for however many mounts.
const instances = new Set()
let installedOn = null
let latest = null

function onKeydown(event) {
  if (latest) latest.handleKey(event)
}

function install(doc) {
  if (installedOn || !doc || typeof doc.addEventListener !== "function") return
  doc.addEventListener("keydown", onKeydown, true)
  installedOn = doc
}

function uninstall() {
  if (!installedOn) return
  installedOn.removeEventListener("keydown", onKeydown, true)
  installedOn = null
}

export function desktop(win = typeof window !== "undefined" ? window : undefined) {
  return !!(win && typeof win.matchMedia === "function" && win.matchMedia(DESKTOP_QUERY).matches)
}

export function isToggle(event) {
  return (
    typeof event.key === "string" &&
    event.key.toLowerCase() === "k" &&
    (event.metaKey || event.ctrlKey) &&
    !event.altKey &&
    !event.shiftKey &&
    !event.isComposing
  )
}

function focusQuietly(el) {
  if (!el || typeof el.focus !== "function") return
  try {
    el.focus({ preventScroll: true })
  } catch (_e) {
    /* element may have unmounted */
  }
}

function selectionOf(doc) {
  const view = doc && doc.defaultView
  const sel = view && typeof view.getSelection === "function" ? view.getSelection() : null
  return sel && typeof sel.getRangeAt === "function" ? sel : null
}

// The caret of a focused contenteditable, if the selection is inside it.
function editableRange(doc, el) {
  if (!el.isContentEditable) return null
  const sel = selectionOf(doc)
  if (!sel || sel.rangeCount === 0) return null
  const range = sel.getRangeAt(0)
  return el.contains(range.startContainer) ? range.cloneRange() : null
}

const CommandPalette = {
  mounted() {
    this.doc = this.el.ownerDocument || (typeof document !== "undefined" ? document : null)
    this.selected = 0
    this.returnTo = null
    this.wasOpen = this.isOpen()
    this.lastQuery = this.renderedQuery()

    this.onScrimClick = (event) => {
      if (event.target === this.el && this.isOpen()) this.pushEventTo(this.el, "palette_close", {})
    }
    this.el.addEventListener("click", this.onScrimClick)

    instances.add(this)
    latest = this
    install(this.doc)
    if (this.wasOpen) this.applySelection()
  },

  updated() {
    const open = this.isOpen()
    const query = this.renderedQuery()

    if (open && !this.wasOpen) {
      this.selected = 0
      if (!this.returnTo) this.remember()
      focusQuietly(this.input())
    }

    if (open) {
      if (query !== this.lastQuery) this.selected = 0
      this.applySelection()
    }

    if (!open && this.wasOpen) this.restoreFocus()

    this.wasOpen = open
    this.lastQuery = query
  },

  destroyed() {
    this.el.removeEventListener("click", this.onScrimClick)
    instances.delete(this)
    if (latest === this) latest = Array.from(instances).pop() || null
    if (instances.size === 0) uninstall()
  },

  handleKey(event) {
    if (isToggle(event)) {
      if (!desktop()) return
      event.preventDefault()
      if (!this.isOpen()) this.remember()
      this.pushEventTo(this.el, "palette_toggle", {})
      return
    }

    if (!this.isOpen()) return

    switch (event.key) {
      case "Escape":
        event.preventDefault()
        event.stopPropagation()
        this.pushEventTo(this.el, "palette_close", {})
        return
      case "ArrowDown":
      case "ArrowUp": {
        const n = this.rows().length
        event.preventDefault()
        if (n === 0) return
        const step = event.key === "ArrowDown" ? 1 : -1
        this.selected = (this.selected + step + n) % n
        this.applySelection()
        return
      }
      case "Enter": {
        if (event.isComposing) return
        event.preventDefault()
        const input = this.input()
        this.pushEventTo(this.el, "palette_go", {
          q: input ? input.value : "",
          index: this.selected,
        })
        return
      }
      default:
        return
    }
  },

  isOpen() {
    return this.el.getAttribute("data-open") === "true"
  },

  input() {
    return this.el.querySelector("#command-palette-input")
  },

  listbox() {
    return this.el.querySelector('[role="listbox"]')
  },

  rows() {
    return Array.from(this.el.querySelectorAll('[role="option"]'))
  },

  renderedQuery() {
    const box = this.listbox()
    return box ? box.getAttribute("data-query") || "" : ""
  },

  remember() {
    const doc = this.doc
    const active = doc && doc.activeElement
    if (!active || active === doc.body || (this.el.contains && this.el.contains(active))) {
      this.returnTo = null
      return
    }
    const caret =
      typeof active.selectionStart === "number"
        ? [active.selectionStart, active.selectionEnd]
        : null
    this.returnTo = { el: active, caret, range: editableRange(doc, active) }
  },

  restoreFocus() {
    const saved = this.returnTo
    this.returnTo = null
    if (!saved || saved.el.isConnected === false) return
    focusQuietly(saved.el)
    if (saved.caret && typeof saved.el.setSelectionRange === "function") {
      try {
        saved.el.setSelectionRange(saved.caret[0], saved.caret[1])
      } catch (_e) {
        /* not a text control any more */
      }
    } else if (saved.range) {
      // A contenteditable (the composer) keeps its caret in the document
      // selection, which the palette input took; put it back.
      const sel = selectionOf(this.doc)
      if (sel) {
        sel.removeAllRanges()
        sel.addRange(saved.range)
      }
    }
  },

  applySelection() {
    const rows = this.rows()
    if (rows.length === 0) {
      this.selected = 0
    } else if (this.selected >= rows.length) {
      this.selected = rows.length - 1
    }

    rows.forEach((row, i) => row.setAttribute("aria-selected", String(i === this.selected)))

    const index = this.el.querySelector('input[name="index"]')
    if (index) index.value = String(this.selected)

    const input = this.input()
    const row = rows[this.selected]
    if (input && row && row.id) input.setAttribute("aria-activedescendant", row.id)

    this.scrollRowIntoView(row)
  },

  // The listbox scrolls, never the page: no scrollIntoView.
  scrollRowIntoView(row) {
    const box = this.listbox()
    if (!row || !box) return
    const top = row.offsetTop
    const bottom = top + row.offsetHeight
    if (top < box.scrollTop) {
      box.scrollTop = top
    } else if (bottom > box.scrollTop + box.clientHeight) {
      box.scrollTop = bottom - box.clientHeight
    }
  },
}

export default CommandPalette
