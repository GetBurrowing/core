// LazyInlineCanvas — mounts a chat message's inline canvas only when it comes
// near the viewport (task 01a13884 stage 4).
//
// Mounted on `#inline-canvas-<message id>` (PlatformWeb.Components.
// ChatInlineCanvas), which wraps EITHER the placeholder (`data-mounted=
// "false"`) OR the rendered canvas document (`data-mounted="true"`). The
// wrapper is the same element in both states, so this hook lives through the
// swap.
//
// Mount request
//   One IntersectionObserver per scroll container (the nearest
//   `[data-scroll-container]`, i.e. `#chat-message-scroller`), shared by every
//   placeholder in it, `rootMargin: "600px 0px"`. On intersect the element is
//   unobserved and its message id queued; the queue is flushed once per task
//   as ONE `inline_canvas_mount` push carrying `message_ids`, so the
//   placeholders that intersect together mount in one server round-trip and
//   one patch instead of one each. Each element requests at most once.
//
// Height memory (Suite.ClientState, never direct localStorage)
//   namespace "chat_ui", key "inline_canvas_heights":
//     { <canvas id>: [height px, scroller width px], ... }   (newest last,
//     capped at MAX_ENTRIES). A mounted canvas's wrapper height is recorded,
//   debounced, whenever it changes; a placeholder for that canvas reserves it
//   when the scroller is the same width (±WIDTH_TOLERANCE px), because the
//   embed scale hook shrinks frames on narrower panes and a height measured
//   at another width would be wrong.
//
// Holding the reader's position
//   The scroller is `overflow-anchor: none`, so the browser does not anchor
//   for us: any element above the viewport that changes height moves every
//   line the reader is looking at. One shared ResizeObserver watches every
//   wrapper; when one whose top is above the scroller's top changes height
//   (the placeholder->document swap, an iframe scaling, a frame loading) the
//   scroller's scrollTop moves by the same delta. ResizeObserver runs after
//   layout and before paint, so the shift is never painted.

import ClientState from "../client_state.js"

export const NAMESPACE = "chat_ui"
export const KEY = "inline_canvas_heights"
export const ROOT_MARGIN = "600px 0px"
export const MAX_ENTRIES = 200
export const WIDTH_TOLERANCE = 8
const RECORD_DEBOUNCE_MS = 300

// ── Height memory ────────────────────────────────────────────────────────────

export function readHeights() {
  const value = ClientState.get(NAMESPACE, KEY, null)
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

export function storedHeight(canvasId, width) {
  const entry = readHeights()[canvasId]
  if (!Array.isArray(entry)) return null
  const [height, measuredAt] = entry
  if (typeof height !== "number" || !(height > 0)) return null
  if (
    typeof width === "number" &&
    typeof measuredAt === "number" &&
    Math.abs(measuredAt - width) > WIDTH_TOLERANCE
  ) {
    return null
  }
  return height
}

export function recordHeight(canvasId, height, width) {
  if (!canvasId || !(height > 0)) return
  const all = readHeights()
  delete all[canvasId]
  all[canvasId] = [Math.round(height), Math.round(width || 0)]
  const keys = Object.keys(all)
  for (let i = 0; i < keys.length - MAX_ENTRIES; i++) delete all[keys[i]]
  ClientState.set(NAMESPACE, KEY, all)
}

// ── Shared observers ─────────────────────────────────────────────────────────

// root (Element | null) -> { io, hooks: Map<Element, hook> }
const intersection = new Map()
// root -> [{hook, id}] waiting for this task's flush
const queues = new Map()

let resizeObserver = null
const resizeHooks = new Map()

// The scroller width read at most once per task: every placeholder mounted in
// one patch shares it, so N placeholders do not force N layouts.
let widthMemo = null

function rootWidth(root) {
  if (widthMemo && widthMemo.root === root) return widthMemo.width
  const width = root ? root.clientWidth : 0
  widthMemo = { root, width }
  queueMicrotask(() => {
    widthMemo = null
  })
  return width
}

function intersectionFor(root) {
  let entry = intersection.get(root)
  if (entry) return entry
  const hooks = new Map()
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue
        const hook = hooks.get(e.target)
        if (hook) hook._requestMount()
      }
    },
    { root, rootMargin: ROOT_MARGIN, threshold: 0 },
  )
  entry = { io, hooks }
  intersection.set(root, entry)
  return entry
}

function enqueue(hook) {
  const root = hook._root
  let queue = queues.get(root)
  if (!queue) {
    queue = []
    queues.set(root, queue)
    queueMicrotask(() => flush(root))
  }
  queue.push(hook)
}

function flush(root) {
  const batch = queues.get(root) || []
  queues.delete(root)
  const ids = batch.map((h) => h.el.dataset.messageId).filter(Boolean)
  if (ids.length === 0) return
  batch[0].pushEvent("inline_canvas_mount", { message_ids: ids })
}

function observeResize(hook) {
  if (typeof ResizeObserver === "undefined") return
  if (!resizeObserver) {
    resizeObserver = new ResizeObserver((entries) => {
      for (const e of entries) {
        const hook = resizeHooks.get(e.target)
        if (hook) hook._onResize(entryHeight(e))
      }
    })
  }
  resizeHooks.set(hook.el, hook)
  resizeObserver.observe(hook.el)
}

function unobserveResize(hook) {
  if (!resizeObserver || !resizeHooks.has(hook.el)) return
  resizeObserver.unobserve(hook.el)
  resizeHooks.delete(hook.el)
  if (resizeHooks.size === 0) {
    resizeObserver.disconnect()
    resizeObserver = null
  }
}

function entryHeight(e) {
  const box = e.borderBoxSize && (e.borderBoxSize[0] || e.borderBoxSize)
  if (box && typeof box.blockSize === "number") return box.blockSize
  return e.contentRect ? e.contentRect.height : 0
}

// ── Hook ─────────────────────────────────────────────────────────────────────

const LazyInlineCanvas = {
  mounted() {
    this._root = this.el.closest("[data-scroll-container]") || null
    this._requested = false
    this._observed = false
    this._lastHeight = null
    this._recordTimer = null
    this._sync()
    observeResize(this)
  },

  updated() {
    this._sync()
  },

  destroyed() {
    this._unobserve()
    unobserveResize(this)
    if (this._recordTimer) clearTimeout(this._recordTimer)
    this._recordTimer = null
  },

  _isMounted() {
    return this.el.dataset.mounted === "true"
  },

  _sync() {
    if (this._isMounted()) {
      this._unobserve()
      return
    }
    this._applyStoredHeight()
    this._observe()
  },

  _applyStoredHeight() {
    const placeholder = this.el.querySelector('[data-role="inline-canvas-placeholder"]')
    if (!placeholder) return
    const height = storedHeight(this.el.dataset.canvasId, rootWidth(this._root))
    if (height) placeholder.style.height = `${height}px`
  },

  _observe() {
    if (this._observed || this._requested) return
    const entry = intersectionFor(this._root)
    entry.hooks.set(this.el, this)
    entry.io.observe(this.el)
    this._observed = true
  },

  _unobserve() {
    if (!this._observed) return
    const entry = intersection.get(this._root)
    if (entry) {
      entry.io.unobserve(this.el)
      entry.hooks.delete(this.el)
      if (entry.hooks.size === 0) {
        entry.io.disconnect()
        intersection.delete(this._root)
      }
    }
    this._observed = false
  },

  _requestMount() {
    if (this._requested || this._isMounted()) return
    this._requested = true
    this._unobserve()
    enqueue(this)
  },

  _onResize(height) {
    const prev = this._lastHeight
    this._lastHeight = height
    if (prev === null || prev === height) return
    if (this._root && this._startsAboveViewport()) {
      this._root.scrollTop += height - prev
    }
    if (this._isMounted()) this._scheduleRecord(height)
  },

  _startsAboveViewport() {
    return this.el.getBoundingClientRect().top < this._root.getBoundingClientRect().top
  },

  _scheduleRecord(height) {
    if (this._recordTimer) clearTimeout(this._recordTimer)
    this._recordTimer = setTimeout(() => {
      this._recordTimer = null
      recordHeight(this.el.dataset.canvasId, height, this._root ? this._root.clientWidth : 0)
    }, RECORD_DEBOUNCE_MS)
  },
}

export function __resetForTests() {
  for (const { io } of intersection.values()) io.disconnect()
  intersection.clear()
  queues.clear()
  if (resizeObserver) resizeObserver.disconnect()
  resizeObserver = null
  resizeHooks.clear()
  widthMemo = null
}

export default LazyInlineCanvas
