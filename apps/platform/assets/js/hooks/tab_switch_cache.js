// TabSwitchCache: what the main pane shows between a tab tap and the
// destination's first render (redesign, tab-switch loading; reference canvas
// 01a16eb5 options 5 "cached-first" and 2 "shimmer skeleton").
//
// THE PICK. "Cached first + shimmer skeleton": a destination you have been to
// in this page session comes back as it looked when you left it, at once,
// with a small "Updating" chip; one you have not seen yet (or a fresh
// install) shows a shimmer skeleton shaped like it. The live render replaces
// either as soon as it lands.
//
// WHERE THE TAP IS CAUGHT. One window-level CAPTURE click listener, the same
// interception point as lib/nav_pending.js: it runs before LiveView's own
// bubble-phase window click handler (which starts the navigation) and before
// RouteResume's document-capture rewrite. The placeholder is in the DOM before
// the click task ends, so it is in the very next frame. Controls: the phone
// tab bar's link tabs, the More sheet's rows and its Settings row, and the
// desktop sidebar's destination rows (`CONTROL_SELECTOR`). The More button
// is not a navigation and is skipped, and so is a tap on the destination you
// are on (the active tab pops to the module root; that is the same page).
//
// WHERE THE PLACEHOLDER GOES. A layer appended to the shell's <main>,
// covering the outgoing page. A tab link is a `navigate`, so LiveView
// destroys the outgoing view in the same click and later swaps the whole
// main element for the new one (`replaceMain`): the layer leaves with the old
// page, with no patch able to touch it in between. `phx:page-loading-stop`
// for the navigation is the backstop that removes it otherwise (a patch, a
// nav_pending rollback), and an 8s timer matches nav_pending's own timeout.
//
// FAST RESPONSES. A cached view is shown at once: it is the expected result,
// so a quick swap to the live render does not flicker. The skeleton and the
// "Updating" chip are in the DOM from the tap but stay invisible for
// FAST_MS (app.css, an animation-delay), so a navigation that lands inside
// ~80ms never shows them.
//
// LATEST TAP WINS. Every tap replaces the layer. LiveView only commits the
// latest pending link, so only the latest navigation ever sends a stop.
//
// THE CACHE. In memory only: a module-level Map that outlives the hook (each
// navigate remounts the shell and so this hook) but not the page. NEVER
// localStorage or sessionStorage: a snapshot holds names and message text.
// At most CACHE_CAP entries, least recently used out first; an entry older
// than MAX_AGE_MS is a miss. Snapshots are taken from the outgoing page when
// you leave it (a tap here, or any `redirect` page-loading-start such as
// back/forward), after the next paint, so the tap's frame only pays for the
// placeholder.
//
// PRIVACY. Cleared when the hook element's `data-user` changes (a different
// person on this socket) and on a tap on the account menu's Log out link.
// Mask names: masking is a server render, so a snapshot taken unmasked holds
// real names. A tap on any mask control (`[phx-click*="mask_names"]`)
// clears the cache and suspends snapshots until the hook sees the new
// `data-masked` (or 10s pass); any change of `data-masked` clears it again;
// and an entry is only shown when it was taken in the current mask state.
//
// A snapshot is inert (`inert` on its root, every id and phx-* binding
// stripped, iframes/media/canvases replaced by empty boxes so nothing
// reloads or plays), and fixed-position descendants are contained by it.

export const HOOK_ID = "tab-switch-cache"
export const CACHE_CAP = 6
export const FAST_MS = 80
export const MAX_AGE_MS = 30 * 60 * 1000
export const TIMEOUT_MS = 8000
export const MASK_SETTLE_MS = 10000
export const UP_TO_DATE_MS = 700
export const UP_TO_DATE_GONE_MS = 1200

export const CONTROL_SELECTOR =
  ".bottom-nav-tab[href], .more-sheet-row[href], .more-sheet-settings[href], .sidebar-row[href]"
export const MAIN_SELECTOR = "main[data-scroll-container]"
export const MASK_SELECTOR = '[phx-click*="mask_names"]'
export const LOGOUT_SELECTOR = 'a[href="/auth/logout"]'
// The phone top strip's page name, outside <main>: it takes the
// destination's label with the placeholder, and gets its text back if the
// switch is abandoned.
export const TITLE_SELECTOR = '[data-role="phone-top-bar-title"]'

export const LAYER_CLASS = "tab-switch-layer"
const CHIP_CLASS = "tab-switch-chip"
// Outgoing-main children that are shell furniture, not page content.
const SKIP_ID = "connection-status"
const MEDIA_SELECTOR = "iframe, video, audio, object, embed, canvas"
const SCROLL_ATTR = "data-tab-switch-scroll"
// Attributes app.css reads document-wide through `:root:has(...)` (they hide
// the tab bar); a snapshot must not carry them.
const DOCUMENT_SIGNAL_ATTRS = new Set(["data-in-call", "data-fullscreen-viewer", "data-bottom-rail"])

const SKELETONS = new Set(["chat", "tasks", "inbox"])

// The skeleton template for a destination key: chat rows, task rows, inbox
// cards, or a generic list for everything else.
export function skeletonKind(key) {
  return SKELETONS.has(key) ? key : "generic"
}

// A small LRU over a Map: `get` does not refresh (a show consumes the entry),
// `set` moves the key to the newest end and evicts past the cap.
export function createSnapshotCache(cap = CACHE_CAP) {
  const map = new Map()
  return {
    get: (key) => map.get(key),
    has: (key) => map.has(key),
    set(key, entry) {
      map.delete(key)
      map.set(key, entry)
      while (map.size > cap) map.delete(map.keys().next().value)
    },
    delete: (key) => map.delete(key),
    clear: () => map.clear(),
    keys: () => Array.from(map.keys()),
    get size() {
      return map.size
    },
  }
}

function plainClick(e) {
  return !(e.button > 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)
}

function closest(target, selector) {
  return target && typeof target.closest === "function" ? target.closest(selector) : null
}

// Strip a cloned subtree of everything live: ids (no duplicates beside the
// page), phx-* and data-phx-* bindings, scripts, media that would load or
// play again (replaced by an empty box that keeps the class and style), and
// the attributes app.css watches document-wide.
export function sanitize(root, doc) {
  for (const el of Array.from(root.querySelectorAll(MEDIA_SELECTOR))) {
    const box = doc.createElement("div")
    const cls = el.getAttribute("class")
    const style = el.getAttribute("style")
    if (cls) box.setAttribute("class", cls)
    if (style) box.setAttribute("style", style)
    el.replaceWith(box)
  }
  for (const el of Array.from(root.querySelectorAll("script"))) el.remove()
  for (const el of [root, ...Array.from(root.querySelectorAll("*"))]) {
    for (const name of el.getAttributeNames()) {
      if (
        name === "id" ||
        name.startsWith("phx-") ||
        name.startsWith("data-phx-") ||
        DOCUMENT_SIGNAL_ATTRS.has(name)
      ) {
        el.removeAttribute(name)
      }
    }
  }
  return root
}

// Indices (in document order) of scrolled elements, so a snapshot comes back
// at the scroll position you left it at. Read from the live page.
function readScroll(nodes) {
  const out = []
  let i = 0
  for (const node of nodes) {
    for (const el of [node, ...Array.from(node.querySelectorAll("*"))]) {
      if (el.scrollTop > 0) out.push([i, el.scrollTop])
      i++
    }
  }
  return out
}

// Mark the clone's counterparts of the scrolled elements (before sanitize can
// change the element count), and scroll them once the snapshot is in the
// document: a detached element cannot hold a scroll offset.
function markScroll(body, scroll) {
  if (!scroll || scroll.length === 0) return
  const all = Array.from(body.querySelectorAll("*"))
  for (const [i, top] of scroll) {
    const el = all[i]
    if (el) el.setAttribute(SCROLL_ATTR, String(top))
  }
}

function applyScroll(body) {
  for (const el of Array.from(body.querySelectorAll(`[${SCROLL_ATTR}]`))) {
    el.scrollTop = Number(el.getAttribute(SCROLL_ATTR)) || 0
  }
}

export function createTabSwitchCache({
  win = window,
  doc = document,
  now = () => (win.performance ? win.performance.now() : Date.now()),
  setTimer = (fn, ms) => win.setTimeout(fn, ms),
  clearTimer = (t) => win.clearTimeout(t),
  // After the next paint: a frame callback, then a task.
  afterPaint = (fn) =>
    typeof win.requestAnimationFrame === "function"
      ? win.requestAnimationFrame(() => win.setTimeout(fn, 0))
      : win.setTimeout(fn, 0),
  cap = CACHE_CAP,
} = {}) {
  const cache = createSnapshotCache(cap)
  const captured = new WeakSet()
  let user
  let masked
  let maskSettling = false
  let maskTimer = null
  let pending = null

  const hookEl = () => doc.getElementById(HOOK_ID)
  const mainEl = () => doc.querySelector(MAIN_SELECTOR)
  const isMasked = (el) => el.getAttribute("data-masked") === "true"

  function clear() {
    cache.clear()
  }

  // The hook element's state, on every mount and update.
  function sync(el) {
    if (!el) return
    const u = el.getAttribute("data-user") || ""
    const m = isMasked(el)
    if (user !== undefined && u !== user) clear()
    if (masked !== undefined && m !== masked) {
      clear()
      endMaskSettle()
    }
    user = u
    masked = m
  }

  function endMaskSettle() {
    maskSettling = false
    if (maskTimer !== null) clearTimer(maskTimer)
    maskTimer = null
  }

  function startMaskSettle() {
    clear()
    endMaskSettle()
    maskSettling = true
    maskTimer = setTimer(endMaskSettle, MASK_SETTLE_MS)
  }

  // Leaving `main`'s page: snapshot it once, after the next paint.
  function captureDeparture(main, el) {
    if (!main || !el || captured.has(main) || maskSettling) return
    const key = el.getAttribute("data-current")
    if (!key) return
    captured.add(main)
    const nodes = Array.from(main.children).filter(
      (n) => n.getAttribute("id") !== SKIP_ID && !n.classList.contains(LAYER_CLASS),
    )
    if (nodes.length === 0) return
    const takenMasked = isMasked(el)
    const takenUser = el.getAttribute("data-user") || ""

    afterPaint(() => {
      if (maskSettling || takenUser !== user || takenMasked !== masked) return
      const scroll = nodes[0].isConnected ? readScroll(nodes) : []
      const body = doc.createElement("div")
      body.className = "tab-switch-snapshot"
      for (const n of nodes) body.appendChild(n.cloneNode(true))
      markScroll(body, scroll)
      sanitize(body, doc)
      cache.set(key, {node: body, masked: takenMasked, user: takenUser, at: now()})
    })
  }

  function usable(entry, el) {
    return (
      entry &&
      !maskSettling &&
      entry.masked === isMasked(el) &&
      entry.user === (el.getAttribute("data-user") || "") &&
      now() - entry.at <= MAX_AGE_MS
    )
  }

  function chip(text, modifier) {
    const c = doc.createElement("div")
    c.className = `${CHIP_CLASS} ${CHIP_CLASS}--${modifier}`
    c.setAttribute("role", "status")
    c.setAttribute("data-role", `tab-switch-${modifier}`)
    if (modifier === "updating") {
      const spin = doc.createElement("span")
      spin.className = "loading loading-spinner loading-xs"
      spin.setAttribute("aria-hidden", "true")
      c.appendChild(spin)
    }
    const label = doc.createElement("span")
    label.textContent = text
    c.appendChild(label)
    return c
  }

  // Take the layer down. A cached view that never got replaced by the live
  // render (superseded, timed out) goes back in the cache.
  function drop(p, {restore}) {
    clearTimer(p.timer)
    if (p.layer.isConnected) p.layer.remove()
    if (restore && p.title && p.title.isConnected) p.title.textContent = p.titleText
    if (restore && p.entry && !cache.has(p.key)) {
      p.entry.node.remove()
      cache.set(p.key, p.entry)
    }
  }

  function show(main, el, key, label) {
    if (pending) drop(pending, {restore: true})
    pending = null
    // A previous switch's "Up to date" says nothing about this one.
    for (const old of Array.from(doc.querySelectorAll(`.${CHIP_CLASS}--done`))) old.remove()

    const layer = doc.createElement("div")
    layer.className = LAYER_CLASS
    layer.setAttribute("data-role", "tab-switch-layer")
    layer.setAttribute("data-destination", key)
    layer.setAttribute("aria-busy", "true")
    layer.setAttribute("aria-label", "Loading")

    const entry = cache.get(key)
    let shown = null
    if (usable(entry, el)) {
      cache.delete(key)
      shown = entry
      entry.node.setAttribute("inert", "")
      layer.setAttribute("data-mode", "cached")
      layer.classList.add(`${LAYER_CLASS}--cached`)
      layer.appendChild(entry.node)
      layer.appendChild(chip("Updating", "updating"))
    } else {
      if (entry && !usable(entry, el)) cache.delete(key)
      const kind = skeletonKind(key)
      const tpl =
        el.querySelector(`template[data-skeleton="${kind}"]`) ||
        el.querySelector('template[data-skeleton="generic"]')
      const body = doc.createElement("div")
      body.className = "tab-switch-skeleton tab-switch-shimmer"
      body.setAttribute("inert", "")
      body.setAttribute("data-skeleton", kind)
      if (tpl && tpl.content) body.appendChild(tpl.content.cloneNode(true))
      layer.setAttribute("data-mode", "skeleton")
      layer.classList.add(`${LAYER_CLASS}--skeleton`)
      layer.appendChild(body)
    }

    main.appendChild(layer)
    if (shown) applyScroll(shown.node)

    const title = doc.querySelector(TITLE_SELECTOR)
    const titleText = title ? title.textContent : null
    if (title && label) title.textContent = label

    const p = {key, layer, entry: shown, at: now(), timer: null, title, titleText}
    p.timer = setTimer(() => {
      if (pending !== p) return
      pending = null
      drop(p, {restore: true})
    }, TIMEOUT_MS)
    pending = p
  }

  // On <body>, fixed at the foot of the pane: the new page's first patches
  // (the shell's async assigns land right after mount) would prune a node
  // LiveView did not render from inside <main>.
  // The redirect's stop can fire before the new <main> is in the document
  // (measured: zero <main> at that moment, the new one lands a few ms
  // later), so wait a few frames for it.
  function upToDate(tries = 10) {
    const main = mainEl()
    if (!main) {
      if (tries > 0) setTimer(() => upToDate(tries - 1), 16)
      return
    }
    if (!doc.body) return
    const c = chip("Up to date", "done")
    c.classList.add(`${CHIP_CLASS}--floating`)
    if (typeof main.getBoundingClientRect === "function") {
      const r = main.getBoundingClientRect()
      const below = Math.max(0, Math.round((win.innerHeight || r.bottom) - r.bottom))
      c.style.bottom = `calc(var(--phone-chrome-bottom, 0px) + ${below + 8}px)`
      c.style.left = `${Math.round(r.left + r.width / 2)}px`
    }
    doc.body.appendChild(c)
    setTimer(() => c.classList.add(`${CHIP_CLASS}--gone`), UP_TO_DATE_MS)
    setTimer(() => c.remove(), UP_TO_DATE_GONE_MS)
  }

  const onClick = (e) => {
    const target = e.target
    if (closest(target, MASK_SELECTOR)) return startMaskSettle()
    if (closest(target, LOGOUT_SELECTOR)) return clear()
    if (!plainClick(e)) return
    const control = closest(target, CONTROL_SELECTOR)
    if (!control) return
    const el = hookEl()
    const main = mainEl()
    if (!el || !main) return
    sync(el)
    const key = control.getAttribute("data-destination")
    if (!key || key === "more" || key === el.getAttribute("data-current")) return

    captureDeparture(main, el)
    show(main, el, key, (control.getAttribute("data-nav-label") || "").trim())
  }

  const onStart = (e) => {
    const detail = (e && e.detail) || {}
    if (detail.kind !== "redirect") return
    const el = hookEl()
    if (el) captureDeparture(mainEl(), el)
  }

  const onStop = (e) => {
    const detail = (e && e.detail) || {}
    if (detail.kind !== "redirect" && detail.kind !== "patch") return
    if (!pending) return
    const p = pending
    pending = null
    drop(p, {restore: false})
    if (p.entry && now() - p.at >= FAST_MS) upToDate()
  }

  win.addEventListener("click", onClick, true)
  win.addEventListener("phx:page-loading-start", onStart)
  win.addEventListener("phx:page-loading-stop", onStop)

  return {
    sync,
    clear,
    cache,
    pending: () => pending,
    maskSettling: () => maskSettling,
    dispose() {
      if (pending) drop(pending, {restore: false})
      pending = null
      endMaskSettle()
      win.removeEventListener("click", onClick, true)
      win.removeEventListener("phx:page-loading-start", onStart)
      win.removeEventListener("phx:page-loading-stop", onStop)
    },
  }
}

// One controller per page, created by the first mount: the hook is remounted
// by every navigate, and the cache has to outlive it.
let controller = null

export function installTabSwitchCache(opts) {
  if (!controller) controller = createTabSwitchCache(opts)
  return controller
}

export function resetTabSwitchCache() {
  if (controller) controller.dispose()
  controller = null
}

const TabSwitchCache = {
  mounted() {
    installTabSwitchCache().sync(this.el)
  },
  updated() {
    installTabSwitchCache().sync(this.el)
  },
}

export default TabSwitchCache
