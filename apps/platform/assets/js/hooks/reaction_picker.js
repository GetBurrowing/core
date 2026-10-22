/**
 * ReactionPicker hook — the ~1,850-emoji picker's whole client surface: the
 * categorised inventory built ONCE, the search field, the ranked result list,
 * and the category jump bar, all inside the picker's `phx-update="ignore"`
 * body host. Task 019e0814 stages 3 and 4.
 *
 * WHY THE GRID IS NOT SERVER-RENDERED. Each tile is ~262 bytes of HTML, so the
 * full inventory is roughly 500KB of markup and ~1,850 DOM nodes. Over the
 * LiveView socket a comprehension sends statics once and per-item dynamics
 * thereafter, which still lands around 180-210KB of real wire bytes per open —
 * `endpoint.ex` sets no `compress:` on the `/live` socket, so permessage-deflate
 * is off. And the picker used to be gated by `:if={@reaction_picker_for}`, so
 * that cost was paid on EVERY open, not once. It is now always mounted and the
 * grid is built here on first open; a later open is a state flip and one
 * attribute write.
 *
 * ## THE LAYERING. Read this before moving any state.
 *
 * Two elements, two owners, and they must not be confused:
 *
 *   #reaction-picker      LIVEVIEW-OWNED. The server drives `data-open` and
 *                         `data-message-id` here. This hook NEVER writes an
 *                         attribute or a class to it — morphdom re-syncs
 *                         attributes on every patch and the chat LiveView
 *                         patches constantly (every message anyone posts), so a
 *                         client-written attribute here would silently vanish
 *                         mid-interaction. That failure reproduces only in a
 *                         busy space.
 *
 *   the hook's own host   `phx-update="ignore"`. Everything this hook builds
 *                         and every flag it sets lives at or below here. Under
 *                         ignore, morphdom merges only `data-*` attributes onto
 *                         the host and never touches its children, so the grid
 *                         survives every patch. NOTHING SERVER-RENDERED INSIDE
 *                         THIS HOST WILL EVER UPDATE — it is written once at
 *                         first render and frozen (task 01a0693d is the bug
 *                         filed when the transcript pane learned that the hard
 *                         way). That is why the host ships empty.
 *
 * THE SEARCH FIELD IS INSIDE THE IGNORED HOST FOR THAT SECOND REASON. A
 * LiveView-owned input would have its `value` re-synced by morphdom on every
 * patch, so anyone posting a message anywhere in the space would wipe what the
 * user had typed. It is built here, its value is client state, and no
 * `phx-change` exists for it — see "no round trips" below.
 *
 * Precedent for the shape: `components/meetings/transcript_pane.ex` +
 * `hooks/meeting_transcript.js`.
 *
 * ## TWO CONTAINERS, EXACTLY ONE VISIBLE
 *
 *   INVENTORY   built once, ~1,850 tiles, sticky category headers, never
 *               reordered and never filtered.
 *   RESULTS     rebuilt from a document fragment per settled query, ranked,
 *               FLAT, no headers.
 *
 * THE FILTER THAT LOOKS RIGHT AND DELETES THE RANKING. The obvious way to
 * search a grid that already exists is to toggle `.hidden` on non-matches,
 * which is what `channel_picker.js:65-78` does and is the only precedent in
 * this codebase. It cannot work here: hidden-toggling leaves the survivors in
 * DATASET order, so `emoji_search.js` computes a ranking and the DOM silently
 * discards it. The grid still looks correct in a screenshot. Two containers is
 * what makes the ranking observable.
 *
 * ## NO ROUND TRIPS
 *
 * Matching runs client-side over the loaded island. There is deliberately NO
 * `phx-change` on the field: the superseded ticket
 * 019e0814-dba5-7e74-84cd-e48e6689f44d proposed one, and it would put a
 * LiveView round trip on every keystroke over an inventory the client already
 * holds. `chat_live_test.exs` asserts no such handler exists.
 *
 * ## THE SWAPPING ROW AND THE ANNOUNCEMENT BUG IT WOULD CAUSE
 *
 * One row under the panel header holds the category jump bar while the field
 * is empty and the result count while it is not. `aria-live` MUST NOT go on
 * that row: swapping its contents destroys and recreates nodes, and a live
 * region created at the moment its text changes announces nothing. The
 * codebase documented that on the deleted mobile drawer's reorder announcer
 * (task 01a1557a-8562 removed the drawer; the Chat list's announcer keeps the
 * same rule).
 * The live region here is a separate visually-hidden element created in
 * `mounted()`, present and empty from mount, and the visible count is
 * `aria-hidden`.
 *
 * ## WHY A MutationObserver AND NOT `updated()`
 *
 * The state that changes is on the PARENT, not on this host. LiveView does call
 * `updated()` for ignored elements, but only when the host's own `data-*`
 * change; open/closed lives on `#reaction-picker`. Observing that element's
 * attributes directly is unambiguous and does not depend on ignore semantics.
 *
 * ## THE EVENT KEY IS HYPHENATED
 *
 * `messages_hooks.ex` matches `handle_event("react", %{"message-id" => _,
 * "emoji" => _}, _)`. An underscore does not match that clause, falls through
 * the hook chain and raises FunctionClauseError. Untargeted `pushEvent` is
 * correct: the handler is on ChatLive, not on a LiveComponent.
 */

import { loadEmoji } from "../lib/load_emoji"
import {
  ariaLabelFor,
  buildSections,
  chunkRows,
  countColumns,
  fillGrid,
  moveChip,
  moveFocus,
  CATEGORY_LABELS,
  COMMON_EMOJI,
  COMMON_SLUG,
} from "../lib/emoji_grid"
import {
  buildCategoryChips,
  buildModeBar,
  buildResults,
  buildSearchField,
} from "../lib/emoji_picker_chrome"
import {
  buildSearchIndex,
  countLabel,
  emptyStateText,
  keyboardInset,
  normalizeQuery,
  rankEmoji,
} from "../lib/emoji_search"

// Stage 3's pure helpers moved to lib/emoji_grid.js when stage 4 gave the
// results container a second caller for the same tile builder. Re-exported
// from here so the module boundary is the only thing that changed and stage
// 3's unit tests keep importing exactly what they imported before.
export {
  ariaLabelFor,
  buildSections,
  chunkRows,
  countColumns,
  moveChip,
  moveFocus,
  CATEGORY_LABELS,
  COMMON_EMOJI,
  COMMON_SLUG,
}

/** Delay before the skeleton paints, so a warm cache never flashes one. */
const SKELETON_DELAY_MS = 150

/** Rows of placeholder tiles painted while the island is in flight. */
const SKELETON_ROWS = 5

/**
 * Trailing debounce on the FILTER. The field is never debounced — characters
 * appear the instant they are typed, and only the grid rebuild waits. House
 * pattern is an inline setTimeout/clearTimeout against a module constant, as
 * in `meeting_room.js:14` and `:136-152`.
 */
const SEARCH_DEBOUNCE_MS = 120

/**
 * How long observer-driven active-category updates are ignored after a chip
 * tap. The jump is instant and traverses up to 1,500 tiles, so the
 * IntersectionObserver fires for every header it passes through; without this
 * the bar visibly walks backwards to wherever the scroll started.
 */
const CATEGORY_TAP_SUPPRESS_MS = 300

/**
 * The observer's top band. Only headers inside the top 15% of the scroll area
 * count as "current", and the LAST one to enter it wins — which is the header
 * whose section the user is actually reading.
 */
const CATEGORY_ROOT_MARGIN = "0px 0px -85% 0px"

/** Desktop, for the two behaviours that differ. See `_isDesktop`. */
const DESKTOP_QUERY = "(min-width: 640px) and (pointer: fine)"

const ReactionPicker = {
  mounted() {
    // The LiveView-owned container. Never written to from here.
    this.picker = this.el.closest(".reaction-picker")
    this.panel = this.picker && this.picker.querySelector(".reaction-picker-panel")

    this.state = "empty" // empty | loading | ready | error
    this.painted = false
    this.api = null
    this.index = []
    this.sections = []
    this.rows = []
    this.inventoryRows = []
    this.resultRows = []
    this.results = []
    this.pos = { r: 0, c: 0 }
    this.columns = 0
    this.searching = false
    this.chromeDesktop = null
    this.chips = []
    this.chipIndex = 0
    this.activeSlug = null
    this.savedInventoryScroll = 0
    this.suppressObserverUntil = 0
    this.keyboardPx = 0
    this.viewportBound = false
    this.previousFocus = null
    this.openedFor = null
    this.lastOutsideFocus = null
    this.scrollLock = null
    this.skeletonTimer = null
    this.searchTimer = null
    this.resizeFrame = null
    this.viewportFrame = null

    // THE LIVE REGION IS CREATED HERE, NOT AT PAINT TIME. `aria-live` only
    // announces CHANGES to a region that was already in the DOM; one created
    // in the same operation that fills it announces nothing. Same reasoning,
    // and the same markup, as the Chat list's reorder announcer.
    this.liveEl = document.createElement("div")
    this.liveEl.className = "reaction-picker-sr"
    this.liveEl.setAttribute("aria-live", "polite")
    this.liveEl.setAttribute("data-role", "reaction-picker-live")
    this.liveEl.textContent = ""
    this.el.appendChild(this.liveEl)

    // Remember what had focus before the picker opened so it can be restored on
    // close. Tracked continuously rather than read at open time: the open
    // travels through a LiveView round trip, and by the time the patch lands the
    // trigger may have been re-rendered out from under `document.activeElement`.
    this.onFocusIn = (e) => {
      if (this.picker && this.picker.contains(e.target)) return
      this.lastOutsideFocus = e.target
    }
    document.addEventListener("focusin", this.onFocusIn, true)

    this.onClick = (e) => this._onClick(e)
    this.el.addEventListener("click", this.onClick)

    this.onKeyDown = (e) => this._onKeyDown(e)
    if (this.picker) this.picker.addEventListener("keydown", this.onKeyDown)

    this.onResize = () => this._onResize()
    window.addEventListener("resize", this.onResize)

    this.onViewportResize = () => this._scheduleKeyboardSync()

    // ONE SWIPE DROPS THE KEYBOARD. Adopted from `search_focus.js (its blur-on-scroll)`,
    // which pairs it with focus-on-entry for the same reason: a field that can
    // raise the keyboard needs a gesture that puts it away, or the user is
    // trapped typing on a surface they came to browse. Passive because nothing
    // here calls preventDefault and scrolling must stay native.
    this.onListTouch = () => {
      if (this.searchInput) this.searchInput.blur()
    }

    // Open/closed is an attribute on the PARENT, so observe the parent.
    if (this.picker && typeof MutationObserver === "function") {
      this.observer = new MutationObserver(() => this._syncOpenState())
      this.observer.observe(this.picker, {
        attributes: true,
        attributeFilter: ["data-open", "data-message-id"],
      })
    }

    this.wasOpen = false
    this._syncOpenState()
  },

  destroyed() {
    document.removeEventListener("focusin", this.onFocusIn, true)
    this.el.removeEventListener("click", this.onClick)
    if (this.picker) this.picker.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("resize", this.onResize)
    if (this.scrollEl) this.scrollEl.removeEventListener("touchstart", this.onListTouch)
    if (this.observer) this.observer.disconnect()
    if (this.skeletonTimer) clearTimeout(this.skeletonTimer)
    if (this.searchTimer) clearTimeout(this.searchTimer)
    if (this.resizeFrame) cancelAnimationFrame(this.resizeFrame)
    this._disconnectCategoryObserver()
    this._releaseScrollLock()
    this._releaseViewport()
  },

  // ── open / closed ────────────────────────────────────────────────────────

  _isOpen() {
    return !!this.picker && this.picker.dataset.open === "true"
  },

  /**
   * Desktop is the fine-pointer half of the ≥640px breakpoint, not the
   * breakpoint alone. Both behaviours that branch on it — autofocusing the
   * field, and sizing the sheet against the keyboard — are about whether a
   * SOFT KEYBOARD exists, and a 10-inch tablet in portrait is over 640px wide
   * with a keyboard that eats half the screen. `app.css` already resolves the
   * same conflict the same way: its coarse-pointer block is deliberately last
   * so touch wins over the 640px rules on a tablet.
   */
  _isDesktop() {
    if (typeof window.matchMedia !== "function") return false
    return window.matchMedia(DESKTOP_QUERY).matches
  },

  _syncOpenState() {
    const open = this._isOpen()
    if (open === this.wasOpen) return
    this.wasOpen = open
    if (open) this._onOpen()
    else this._onClose()
  },

  _onOpen() {
    // Remember WHICH MESSAGE, not only which node. The node can be replaced by
    // any later patch; the message id is stable and re-queryable. See _onClose.
    this.openedFor = (this.picker && this.picker.dataset.messageId) || null
    this.previousFocus = this._resolveTrigger()
    this._takeScrollLock()
    this._observeViewport()
    this._render()

    // EVERY OPEN STARTS CLEAN: empty field, inventory mode, scroll at the top.
    // A query or a deep scroll carried across a close and a reopen on a
    // different message reads as a bug.
    this._resetSearch()

    // Initial focus. Desktop puts it in the field: the picker is nearly always
    // opened with an emoji already in mind and the keyboard is right there.
    // Mobile MUST NOT — raising the soft keyboard unbidden collapses the grid
    // to two rows before the user has decided they need to search — so it
    // anchors on the panel, which carries `tabindex="-1"` and the dialog's
    // `aria-label`.
    this._focusOnOpen()
  },

  _focusOnOpen() {
    if (this._isDesktop() && this.searchInput) {
      // NOT the HTML `autofocus` attribute. `search_focus.js (its focus-on-mount)`
      // records that it no-ops on iOS Safari when the element renders after a
      // LiveView round trip, outside the original tap's gesture chain.
      // preventScroll so focusing never yanks the freshly-opened panel.
      this.searchInput.focus({ preventScroll: true })
      return
    }
    if (this.panel) this.panel.focus({ preventScroll: true })
  },

  /**
   * What to give focus back to on close, in descending order of confidence.
   *
   * Three sources because none of them is reliable alone. `document.activeElement`
   * is right for a keyboard open (Tab to the "+", press Enter) but is `body`
   * after a plain `.click()`, and Safari does not focus a button on a real mouse
   * click either. `lastOutsideFocus` covers the mouse case on browsers that DO
   * focus, but the element can be re-rendered away by the same patch that opens
   * the picker. The last resort is deterministic and needs no history at all:
   * the server told us which message this picker is for, and that message's
   * add-reaction button is the control that opened it.
   *
   * Dropping to `null` and leaving focus on `<body>` is the outcome worth
   * avoiding: a keyboard user who closes the picker would be returned to the top
   * of the document, several hundred tab stops from the message they were on.
   */
  _resolveTrigger() {
    const active = document.activeElement
    if (active && active !== document.body && !(this.picker && this.picker.contains(active))) {
      return active
    }
    if (this.lastOutsideFocus && this.lastOutsideFocus.isConnected) return this.lastOutsideFocus
    return this._triggerForMessage(this.picker && this.picker.dataset.messageId)
  },

  /**
   * The add-reaction control for a given message, looked up fresh.
   *
   * MEASURED, 2026-09-06: holding the node from open time is not enough. The
   * "+" button carries no `id`, so a LiveView patch between open and close can
   * hand back a different element for the same control, and the captured
   * reference is then detached — `isConnected` false, restore skipped, focus
   * left on `<body>`. A keyboard user closing the picker would land at the top
   * of the document, several hundred tab stops from the message they were on.
   * Driving it in a real browser is what surfaced this; no LiveView test can,
   * because focus restoration is entirely client-side.
   */
  _triggerForMessage(messageId) {
    if (!messageId) return null
    return document.querySelector(
      `[phx-click="open_reaction_picker"][phx-value-message-id="${CSS.escape(messageId)}"]`
    )
  },

  _onClose() {
    this._releaseScrollLock()
    // The SAME teardown releases the visualViewport listener. That pairing is
    // the fix for the leak: the picker opens and closes many times in a
    // session, and an open that adds a listener without a close that removes
    // it accumulates one handler per open on a global object.
    this._releaseViewport()

    const held = this.previousFocus
    const target =
      held && held.isConnected ? held : this._triggerForMessage(this.openedFor)
    this.previousFocus = null
    this.openedFor = null
    if (!target) return

    // TWICE, and both calls are load-bearing.
    //
    // The immediate one is the restore. `sheet.js` defers this to a
    // `requestAnimationFrame` alone, and rAF does not run in a tab the browser
    // has backgrounded or throttled — measured in headless Chrome on
    // 2026-09-06, where the deferred-only version left focus on `<body>` every
    // time. A focus restore that silently does nothing is worse than no
    // restore, because nothing looks wrong until a keyboard user closes the
    // picker and finds themselves at the top of the document.
    //
    // The deferred one is the fix sheet.js was actually written for: the close
    // button's own blur can steal focus back within the same frame.
    const restore = () => {
      try {
        target.focus({ preventScroll: true })
      } catch (_e) {
        /* trigger unmounted between frames */
      }
    }
    restore()
    requestAnimationFrame(restore)
  },

  // Body scroll lock for the picker's own lifetime. `message_lift.js` also
  // locks, but its lock is GONE by the time we need one: the longpress "more"
  // button pushes `open_reaction_picker` and then `close_longpress_menu`, so
  // MessageLift is destroyed — restoring `body.style.overflow` — in the same
  // patch that opens the picker.
  _takeScrollLock() {
    if (this.scrollLock !== null) return
    this.scrollLock = document.body.style.overflow
    document.body.style.overflow = "hidden"
  },

  _releaseScrollLock() {
    if (this.scrollLock === null) return
    document.body.style.overflow = this.scrollLock
    this.scrollLock = null
  },

  // ── the mobile keyboard ──────────────────────────────────────────────────

  /**
   * Size the sheet against `window.visualViewport`.
   *
   * `.reaction-picker-panel` is `max-height: 60vh` on mobile and `70vh` at
   * ≥640px, both in `vh`. `vh` is the LAYOUT viewport, which a soft keyboard
   * does not shrink on iOS Safari, so a keyboard-open sheet ends up partly
   * underneath the keyboard with the search field — the one control the user
   * is looking at — hidden behind it.
   *
   * WHY A NAIVE TEST PASSES AND IT IS STILL BROKEN. `root.html.heex:6-7` sets
   * `interactive-widget=resizes-content`, which on Chrome/Android resizes the
   * LAYOUT viewport too, so `vh` shrinks and the bug does not reproduce. iOS
   * Safari ignores that hint. ANDROID CHROME WILL SHOW YOU A WORKING SHEET.
   *
   * This is the FIRST `visualViewport` usage in this codebase — a grep of
   * assets/ before this returned one comment (`message_lift.js:96`) and zero
   * usages — so it is written long rather than clever.
   *
   * The measured height lands on `<html>` as a custom property rather than as
   * an inline style on the panel. The panel is LIVEVIEW-OWNED: morphdom
   * re-syncs its attributes on every patch and the chat LiveView patches on
   * every message anyone posts, so a `style` written here would vanish
   * mid-interaction in exactly a busy space. `<html>` is outside the LiveView
   * tree and is never patched.
   */
  _observeViewport() {
    const vv = window.visualViewport
    if (!vv || typeof vv.addEventListener !== "function") return
    if (this.viewportBound) return
    vv.addEventListener("resize", this.onViewportResize)
    this.viewportBound = true
    this._syncKeyboardInset()
  },

  _releaseViewport() {
    const vv = window.visualViewport
    if (vv && typeof vv.removeEventListener === "function" && this.viewportBound) {
      vv.removeEventListener("resize", this.onViewportResize)
    }
    this.viewportBound = false
    if (this.viewportFrame) {
      cancelAnimationFrame(this.viewportFrame)
      this.viewportFrame = null
    }
    this.keyboardPx = 0
    document.documentElement.style.removeProperty("--reaction-picker-kb")
  },

  // Coalesced into one frame: iOS fires `resize` repeatedly through the
  // keyboard's own animation, and writing a custom property per event forces a
  // style recalculation on each one.
  _scheduleKeyboardSync() {
    if (this.viewportFrame) return
    this.viewportFrame = requestAnimationFrame(() => {
      this.viewportFrame = null
      this._syncKeyboardInset()
    })
  },

  _syncKeyboardInset() {
    const vv = window.visualViewport
    if (!vv) return
    // The 120px floor is the URL-bar guard — see `keyboardInset`.
    const px = keyboardInset(window.innerHeight, vv.height)
    if (px === this.keyboardPx) return
    this.keyboardPx = px
    document.documentElement.style.setProperty("--reaction-picker-kb", `${px}px`)
  },

  // ── loading ──────────────────────────────────────────────────────────────

  /**
   * Paint whatever the current state warrants — but ONLY WHILE OPEN.
   *
   * This gate is load-bearing, not defensive tidiness. Building the grid needs
   * the live column count, and the only honest source of that is the laid-out
   * CSS grid: `auto-fit` on a coarse pointer packs six columns at 375px and
   * seven at 430px, and neither number exists anywhere in JS. A `display: none`
   * panel has no layout, so measuring one yields the unresolved
   * `repeat(auto-fit, ...)` string and rows of the wrong size. The island
   * resolving while the picker is closed is the ordinary case — the user opens,
   * waits, gives up and closes — so this is a path that WILL be taken.
   */
  _render() {
    if (!this._isOpen() || this.painted) return

    switch (this.state) {
      case "empty":
        this._load()
        return
      case "loading":
        // The skeleton timer owns this window.
        return
      case "ready":
        this._renderInventory(this.api)
        this.painted = true
        return
      case "error":
        this._renderError()
        this.painted = true
    }
  },

  _load() {
    this.state = "loading"
    this.painted = false

    // Delay guard: a warm cache resolves in well under a frame, and a skeleton
    // that flashes for 20ms reads as a glitch rather than as progress.
    this.skeletonTimer = setTimeout(() => {
      this.skeletonTimer = null
      if (this.state === "loading" && this._isOpen()) this._renderSkeleton()
    }, SKELETON_DELAY_MS)

    loadEmoji()
      .then((api) => {
        this._clearSkeletonTimer()
        this.api = api
        this.state = "ready"
        this.painted = false
        this._render()
      })
      .catch(() => {
        this._clearSkeletonTimer()
        this.state = "error"
        this.painted = false
        this._render()
      })
  },

  _clearSkeletonTimer() {
    if (!this.skeletonTimer) return
    clearTimeout(this.skeletonTimer)
    this.skeletonTimer = null
  },

  // ── rendering ────────────────────────────────────────────────────────────

  /**
   * Clear the host back to its scroll area, KEEPING the live region.
   *
   * The live region is the one child that must survive every repaint: it has to
   * predate the text it announces, so re-creating it alongside a fresh count is
   * exactly the bug it exists to avoid.
   */
  _resetHost() {
    this._disconnectCategoryObserver()
    if (this.scrollEl) this.scrollEl.removeEventListener("touchstart", this.onListTouch)

    for (const child of Array.from(this.el.children)) {
      if (child !== this.liveEl) child.remove()
    }
    if (!this.liveEl.isConnected) this.el.appendChild(this.liveEl)

    this.searchWrap = null
    this.searchInput = null
    this.clearBtn = null
    this.modeBar = null
    this.jumpBar = null
    this.countEl = null
    this.inventoryEl = null
    this.resultsEl = null
    this.resultsGrid = null
    this.emptyEl = null
    this.chips = []
    this.chipIndex = 0
    this.activeSlug = null
    this.searching = false
    this.chromeDesktop = null
    this.rows = []
    this.inventoryRows = []
    this.resultRows = []

    this.scrollEl = document.createElement("div")
    this.scrollEl.className = "reaction-picker-scroll"
    this.scrollEl.setAttribute("data-role", "reaction-picker-scroll")
    this.scrollEl.addEventListener("touchstart", this.onListTouch, { passive: true })
    this.el.appendChild(this.scrollEl)
    return this.scrollEl
  },

  /**
   * Measure the live column count off a real, laid-out grid.
   *
   * A probe is needed before the first build because `auto-fit` COLLAPSES empty
   * tracks: an empty grid reports one track or none, whichever breakpoint it is
   * under. Twelve placeholder tiles is enough to saturate every column count
   * this design produces (6 on touch, 8 on desktop).
   */
  _measureColumns(scrollEl) {
    const existing = scrollEl.querySelector(".reaction-picker-grid")
    if (existing) {
      const n = countColumns(getComputedStyle(existing).gridTemplateColumns)
      if (n > 0) return n
    }

    const probe = document.createElement("div")
    probe.className = "reaction-picker-grid"
    probe.setAttribute("aria-hidden", "true")
    for (let i = 0; i < 12; i++) {
      const tile = document.createElement("span")
      tile.className = "reaction-picker-tile"
      probe.appendChild(tile)
    }
    scrollEl.appendChild(probe)
    const n = countColumns(getComputedStyle(probe).gridTemplateColumns)
    probe.remove()
    return n > 0 ? n : 8
  },

  _renderSkeleton() {
    const scrollEl = this._resetHost()
    const columns = this._measureColumns(scrollEl)

    // Hold the real tile geometry rather than centring a spinner: a late height
    // change would fight the mobile sheet sizing.
    const grid = document.createElement("div")
    grid.className = "reaction-picker-grid"
    grid.setAttribute("aria-hidden", "true")
    grid.setAttribute("data-role", "reaction-picker-skeleton")
    for (let i = 0; i < columns * SKELETON_ROWS; i++) {
      const cell = document.createElement("div")
      cell.className = "reaction-picker-tile reaction-picker-skeleton-tile"
      grid.appendChild(cell)
    }
    scrollEl.appendChild(grid)
  },

  /**
   * Fetch failure. NO SEARCH FIELD AND NO JUMP BAR HERE: both are surfaces over
   * an inventory that never arrived, and a field that can only ever return
   * nothing is worse than no field.
   */
  _renderError() {
    const scrollEl = this._resetHost()

    const box = document.createElement("div")
    box.className = "reaction-picker-error"
    box.setAttribute("data-role", "reaction-picker-error")

    // No semantic colour is available in this picker, so the copy carries the
    // meaning. This is also the one moment nothing else on the surface wants
    // `primary`, which is why the retry can hold the focus ring alone.
    const line = document.createElement("p")
    line.className = "reaction-picker-error-text"
    line.textContent = "Couldn't load emoji. Check your connection."
    box.appendChild(line)

    const retry = document.createElement("button")
    retry.type = "button"
    retry.className = "reaction-picker-retry"
    retry.setAttribute("data-role", "reaction-picker-retry")
    retry.textContent = "Try again"
    box.appendChild(retry)

    scrollEl.appendChild(box)

    // COMMON underneath, so a reaction is still possible offline. Repeat
    // failures show the same copy; no escalation.
    this.sections = [
      {
        slug: COMMON_SLUG,
        label: CATEGORY_LABELS[COMMON_SLUG],
        entries: COMMON_EMOJI.map((e) => ({ e, n: "", k: [], c: COMMON_SLUG })),
      },
    ]
    this.index = []
    this._paintInventory(scrollEl)
  },

  _renderInventory(api) {
    const scrollEl = this._resetHost()
    this.sections = buildSections(api.EMOJI, api.CATEGORIES)
    this.index = buildSearchIndex(api.EMOJI)

    this._buildSearchField()
    this._buildModeBar()
    this._placeChrome()
    this._paintInventory(scrollEl)
    this._buildResultsContainer(scrollEl)
    this._buildJumpBar()
    this._observeCategories()
    if (this.sections.length) this._setActiveChip(this.sections[0].slug, false)

    // The island can resolve long after the open, so the focus decision has to
    // be taken again here. Only claim focus if nothing inside the panel has it
    // yet — a user who reached a tile during the skeleton keeps it.
    const active = document.activeElement
    if (!active || active === document.body || active === this.panel) this._focusOnOpen()
  },

  // ── chrome: the field, the swapping row, the jump bar ────────────────────
  //
  // The elements themselves are built by `lib/emoji_picker_chrome.js`, which
  // carries the rationale for each attribute. What stays here is the wiring:
  // which listener goes on what, and where each piece sits in the DOM.

  _buildSearchField() {
    const { wrap, input, clear } = buildSearchField(document)

    this.onSearchInput = () => this._onSearchInput()
    input.addEventListener("input", this.onSearchInput)

    this.searchWrap = wrap
    this.searchInput = input
    this.clearBtn = clear
  },

  _buildModeBar() {
    const { bar, jumpBar, count } = buildModeBar(document)
    this.modeBar = bar
    this.jumpBar = jumpBar
    this.countEl = count
  },

  /**
   * DOM ORDER IS THE TAB ORDER, so the two breakpoints get two orders rather
   * than one order plus a CSS `order` override. A flex `order` that moved the
   * field visually would leave a desktop keyboard user tabbing grid-then-field
   * while looking at field-then-grid, which is WCAG 2.4.3.
   *
   *   desktop   field, row, grid    the field is the fast path and the keyboard
   *                                 is already there
   *   mobile    row, grid, field    the keyboard eats from the bottom up, so
   *                                 the field sits directly above it and the
   *                                 results land nearest the thumb
   *
   * GUARDED ON AN ACTUAL BREAKPOINT CHANGE. `insertBefore` on a node that is
   * already in place still detaches and re-inserts it, which BLURS a focused
   * input. `_onResize` fires on every URL-bar collapse, so an unguarded call
   * would drop the caret out of the field mid-scroll.
   */
  _placeChrome() {
    if (!this.searchWrap || !this.modeBar || !this.scrollEl) return
    const desktop = this._isDesktop()
    if (this.chromeDesktop === desktop) return
    this.chromeDesktop = desktop

    if (desktop) {
      this.el.insertBefore(this.searchWrap, this.scrollEl)
      this.el.insertBefore(this.modeBar, this.scrollEl)
    } else {
      this.el.insertBefore(this.modeBar, this.scrollEl)
      this.el.appendChild(this.searchWrap)
    }
  },

  _buildJumpBar() {
    if (!this.jumpBar) return
    this.chips = buildCategoryChips(document, this.jumpBar, this.sections)
    this.chipIndex = 0
  },

  // ── the two containers ───────────────────────────────────────────────────

  _paintInventory(scrollEl) {
    const columns = this._measureColumns(scrollEl)
    this.columns = columns

    const inventory = document.createElement("div")
    inventory.className = "reaction-picker-inventory"
    inventory.setAttribute("data-role", "reaction-picker-inventory")

    const frag = document.createDocumentFragment()
    this.inventoryRows = []

    for (const section of this.sections) {
      const wrap = document.createElement("div")
      wrap.className = "reaction-picker-section"
      wrap.setAttribute("data-category", section.slug)

      const headingId = `reaction-picker-cat-${section.slug}`
      const heading = document.createElement("div")
      heading.className = "reaction-picker-category"
      heading.id = headingId
      heading.setAttribute("data-category", section.slug)
      heading.textContent = section.label
      wrap.appendChild(heading)

      const grid = document.createElement("div")
      grid.className = "reaction-picker-grid"
      grid.setAttribute("role", "grid")
      grid.setAttribute("aria-labelledby", headingId)

      for (const tiles of fillGrid(document, grid, section.entries, columns)) {
        this.inventoryRows.push(tiles)
      }

      wrap.appendChild(grid)
      frag.appendChild(wrap)
    }

    inventory.appendChild(frag)
    scrollEl.appendChild(inventory)
    this.inventoryEl = inventory

    this.rows = this.inventoryRows
    this.pos = { r: 0, c: 0 }
    this._seedRovingTabindex()
  },

  _buildResultsContainer(scrollEl) {
    const { results, grid, empty } = buildResults(document)
    scrollEl.appendChild(results)
    this.resultsEl = results
    this.resultsGrid = grid
    this.emptyEl = empty
  },

  // ── search ───────────────────────────────────────────────────────────────

  /**
   * DEBOUNCE THE FILTER, NEVER THE FIELD. The typed character is already on
   * screen — the browser painted it — and only the rebuild waits 120ms. A
   * debounce applied to the input's own value is how a search box comes to feel
   * broken.
   *
   * Emptying the field is immediate. Waiting 120ms to return to the inventory
   * after the user has cleared it is the one delay they would notice, because
   * they are usually holding backspace when it happens.
   *
   * Nothing dims, fades or spins between keystrokes: the previous results and
   * the previous count stay at full opacity until the new ones land. A
   * per-keystroke transition is the thing that reads as slow.
   */
  _onSearchInput() {
    const raw = this.searchInput ? this.searchInput.value : ""
    this._syncClearButton(raw)

    if (this.searchTimer) {
      clearTimeout(this.searchTimer)
      this.searchTimer = null
    }

    if (normalizeQuery(raw) === "") {
      this._applyQuery(raw)
      return
    }

    this.searchTimer = setTimeout(() => {
      this.searchTimer = null
      this._applyQuery(raw)
    }, SEARCH_DEBOUNCE_MS)
  },

  _syncClearButton(raw) {
    if (!this.clearBtn) return
    // One or more characters, focused or not. The input reserves the button's
    // width as padding in every state, so this never shifts the text.
    this.clearBtn.hidden = String(raw || "").length === 0
  },

  _applyQuery(raw) {
    if (!this.resultsEl || !this.inventoryEl) return
    const searching = normalizeQuery(raw) !== ""

    if (searching) {
      this.results = rankEmoji(raw, this.index)
      this._paintResults(raw)
    }

    this._setMode(searching)

    if (searching) {
      const text = countLabel(this.results.length)
      if (this.countEl) this.countEl.textContent = text
      // The SETTLED count, on the region that has been mounted since the hook
      // was. It is not touched between keystrokes, so a fast typist gets one
      // announcement rather than one per character.
      if (this.liveEl) this.liveEl.textContent = text
    } else if (this.liveEl) {
      this.liveEl.textContent = ""
    }
  },

  _paintResults(raw) {
    if (!this.resultsGrid) return
    this.resultsGrid.textContent = ""

    // A FRESH BUILD FROM A FRAGMENT, because the ranking is the point. Toggling
    // `.hidden` over the inventory would return matches in dataset order and
    // still look correct. See the moduledoc.
    const staging = document.createElement("div")
    this.resultRows = fillGrid(document, staging, this.results, this.columns || 8)
    const frag = document.createDocumentFragment()
    while (staging.firstChild) frag.appendChild(staging.firstChild)
    this.resultsGrid.appendChild(frag)

    if (this.emptyEl) {
      this.emptyEl.hidden = this.results.length > 0
      if (this.results.length === 0) this.emptyEl.textContent = emptyStateText(raw)
    }
  },

  /**
   * Flip between the two containers, moving the scroll position with it.
   *
   * `display: none` does not preserve `scrollTop` reliably, so the inventory's
   * offset is saved on the way out and restored on the way back. Results always
   * start at 0 and stay at 0 as the query is refined: a ranked list whose best
   * match is off-screen because of where the inventory happened to be is the
   * bug that prevents.
   */
  _setMode(searching) {
    if (searching === this.searching) {
      // Same mode, new rows: refining a query rebuilds the result tiles, and
      // the roving tabindex still points into the previous fragment.
      if (searching) this._afterRowsRebuilt()
      return
    }

    if (searching) this.savedInventoryScroll = this.scrollEl ? this.scrollEl.scrollTop : 0

    this.searching = searching
    this.inventoryEl.hidden = searching
    this.resultsEl.hidden = !searching
    if (this.jumpBar) this.jumpBar.hidden = searching
    if (this.countEl) this.countEl.hidden = !searching

    if (this.scrollEl) {
      this.scrollEl.scrollTop = searching ? 0 : this.savedInventoryScroll || 0
    }

    this._afterRowsRebuilt()
  },

  /**
   * RE-SEED AFTER EVERY REBUILD. The previously tabbable cell belongs to the
   * container that just went away, or to the previous query's fragment; either
   * way it is a detached node, and a roving tabindex pointing at one means the
   * next Tab lands nowhere and the arrow keys stop working mid-search.
   */
  _afterRowsRebuilt() {
    this.rows = this.searching ? this.resultRows : this.inventoryRows
    this.pos = { r: 0, c: 0 }
    this._seedRovingTabindex()
  },

  _resetSearch() {
    if (this.searchTimer) {
      clearTimeout(this.searchTimer)
      this.searchTimer = null
    }
    if (this.searchInput) this.searchInput.value = ""
    this._syncClearButton("")
    if (this.inventoryEl && this.resultsEl) this._applyQuery("")
    this.savedInventoryScroll = 0
    if (this.scrollEl) this.scrollEl.scrollTop = 0
    if (this.sections.length) this._setActiveChip(this.sections[0].slug, false)
  },

  /**
   * Exactly one tile carries `tabindex="0"`; every other is `-1`. That reduces
   * the dialog's focusable set to about four elements, which is what makes the
   * Tab trap below cheap.
   */
  _seedRovingTabindex() {
    for (const row of this.inventoryRows) for (const tile of row) tile.setAttribute("tabindex", "-1")
    for (const row of this.resultRows) for (const tile of row) tile.setAttribute("tabindex", "-1")
    const tile = this._tileAt(this.pos)
    if (tile) tile.setAttribute("tabindex", "0")
  },

  _tileAt(pos) {
    const row = this.rows[pos.r]
    return row ? row[pos.c] : null
  },

  // ── the category jump bar ────────────────────────────────────────────────

  /**
   * Active category from the sticky headers, never from a scroll handler.
   *
   * `rootMargin: "0px 0px -85% 0px"` shrinks the observation box to the top 15%
   * of the scroll area, so "intersecting" means "at or near the top edge", and
   * the LAST such header in document order is the section being read. A
   * per-frame scroll listener over a 1,850-tile list is the alternative, and it
   * costs a layout read on every frame of every flick.
   */
  _observeCategories() {
    if (typeof IntersectionObserver !== "function" || !this.scrollEl || !this.inventoryEl) return

    this.visibleHeaders = new Set()
    this.categoryObserver = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const slug = entry.target.dataset.category
          if (!slug) continue
          if (entry.isIntersecting) this.visibleHeaders.add(slug)
          else this.visibleHeaders.delete(slug)
        }

        // A tap jump scrolls THROUGH every header between here and there, so
        // the observer fires for all of them and would drag the bar backwards
        // to wherever the scroll started. Ignore it until the jump has settled.
        if (Date.now() < this.suppressObserverUntil) return

        let last = null
        for (const section of this.sections) {
          if (this.visibleHeaders.has(section.slug)) last = section.slug
        }
        if (last) this._setActiveChip(last, true)
      },
      { root: this.scrollEl, rootMargin: CATEGORY_ROOT_MARGIN, threshold: 0 }
    )

    for (const heading of this.inventoryEl.querySelectorAll(".reaction-picker-category")) {
      this.categoryObserver.observe(heading)
    }
  },

  _disconnectCategoryObserver() {
    if (!this.categoryObserver) return
    this.categoryObserver.disconnect()
    this.categoryObserver = null
  },

  /**
   * `scrollIntoView` ONLY on observer-driven changes. On a tap the user is
   * already looking at the chip they pressed, and scrolling the bar under their
   * finger moves the target of the next tap.
   */
  _setActiveChip(slug, scrollChipIntoView) {
    if (!slug || slug === this.activeSlug) return
    this.activeSlug = slug
    for (const chip of this.chips) {
      const active = chip.dataset.category === slug
      if (active) chip.setAttribute("aria-current", "true")
      else chip.removeAttribute("aria-current")
      if (active && scrollChipIntoView && typeof chip.scrollIntoView === "function") {
        chip.scrollIntoView({ block: "nearest", inline: "nearest" })
      }
    }
  },

  /**
   * Jump to a category's header.
   *
   * An explicit `scrollTop` write IS `behavior: "instant"`. A smooth scroll from
   * Flags back to Common traverses ~1,500 tiles and takes seconds, during which
   * the picker looks frozen and every intermediate header fires the observer.
   */
  _jumpToCategory(slug) {
    if (!this.inventoryEl || !this.scrollEl || !slug) return
    const section = this.inventoryEl.querySelector(
      `.reaction-picker-section[data-category="${CSS.escape(slug)}"]`
    )
    if (!section) return

    this.suppressObserverUntil = Date.now() + CATEGORY_TAP_SUPPRESS_MS
    const delta = section.getBoundingClientRect().top - this.scrollEl.getBoundingClientRect().top
    this.scrollEl.scrollTop += delta
    this._setActiveChip(slug, false)
  },

  _focusChip(index) {
    if (!this.chips.length) return
    const i = Math.min(Math.max(index, 0), this.chips.length - 1)
    for (const chip of this.chips) chip.setAttribute("tabindex", "-1")
    this.chipIndex = i
    this.chips[i].setAttribute("tabindex", "0")
    this.chips[i].focus({ preventScroll: true })
  },

  // ── interaction ──────────────────────────────────────────────────────────

  _onClick(e) {
    const retry = e.target.closest && e.target.closest("[data-role='reaction-picker-retry']")
    if (retry) {
      this.state = "empty"
      this.painted = false
      this._render()
      return
    }

    const clear = e.target.closest && e.target.closest("[data-role='reaction-picker-search-clear']")
    if (clear) {
      this._clearSearch()
      return
    }

    const chip = e.target.closest && e.target.closest(".reaction-picker-chip")
    if (chip) {
      const index = this.chips.indexOf(chip)
      if (index !== -1) this._focusChip(index)
      this._jumpToCategory(chip.dataset.category)
      return
    }

    const tile = e.target.closest && e.target.closest(".reaction-picker-tile[data-emoji]")
    if (!tile) return
    this._react(tile.dataset.emoji)
  },

  /**
   * Clear, then REFOCUS THE INPUT SYNCHRONOUSLY IN THE SAME HANDLER. Deferring
   * it to a timer or a frame drops focus first, and on mobile that closes the
   * soft keyboard and resizes the sheet under the user's thumb between the tap
   * and the refocus. The grid returns to the inventory at its saved offset,
   * which `_applyQuery("")` does through `_setMode`.
   */
  _clearSearch() {
    if (!this.searchInput) return
    if (this.searchTimer) {
      clearTimeout(this.searchTimer)
      this.searchTimer = null
    }
    this.searchInput.value = ""
    this._syncClearButton("")
    this.searchInput.focus({ preventScroll: true })
    this._applyQuery("")
  },

  _react(emoji) {
    const messageId = this.picker && this.picker.dataset.messageId
    if (!messageId || !emoji) return

    // HYPHENATED KEY. See the moduledoc: "message_id" does not match the
    // server's clause and falls through to a FunctionClauseError.
    this.pushEvent("react", { "message-id": messageId, emoji })
  },

  _onKeyDown(e) {
    if (!this._isOpen()) return

    if (e.key === "Tab") {
      this._trapTab(e)
      return
    }

    if (this.searchInput && e.target === this.searchInput) {
      this._onSearchKeyDown(e)
      return
    }

    const chip = e.target.closest && e.target.closest(".reaction-picker-chip")
    if (chip) {
      // Enter and Space are the button's own activation; the click handler owns
      // the jump so it is written once.
      if (e.key === "Enter" || e.key === " ") return
      const next = moveChip(this.chips.length, this.chips.indexOf(chip), e.key)
      if (next === null) return
      e.preventDefault()
      this._focusChip(next)
      return
    }

    const tile = e.target.closest && e.target.closest(".reaction-picker-tile[data-emoji]")
    if (!tile) return

    const pos = this._positionOf(tile)
    if (!pos) return

    const next = moveFocus(this.rows, pos, e.key)
    if (!next) return

    e.preventDefault()
    this._focusTile(next)
  },

  _onSearchKeyDown(e) {
    // ArrowDown walks out of the field into the first cell, so the whole
    // surface is reachable from the field without a Tab.
    if (e.key === "ArrowDown") {
      if (!this.rows.length) return
      e.preventDefault()
      this._focusTile({ r: 0, c: 0 })
      return
    }

    if (e.key === "Enter") {
      // Enter applies the FIRST RANKED result, which is what ranking is for.
      // Zero results is a no-op rather than a close: closing on a failed search
      // loses the message the user was reacting to. An empty field is also a
      // no-op — Enter there would fire the first COMMON tile at random.
      if (!this.searching) return
      const first = this._tileAt({ r: 0, c: 0 })
      if (!first) return
      e.preventDefault()
      this._react(first.dataset.emoji)
      return
    }

    // BACKSPACE ON AN EMPTY FIELD IS A NO-OP. It is deliberately not handled
    // here, and nothing else in this hook closes on it — a picker that closes
    // on a stray keystroke loses the message being reacted to. This comment
    // exists because "clear on backspace, close on the next one" is what an
    // implementer adds by reflex.
  },

  _positionOf(tile) {
    for (let r = 0; r < this.rows.length; r++) {
      const c = this.rows[r].indexOf(tile)
      if (c !== -1) return { r, c }
    }
    return null
  },

  _focusTile(pos) {
    const current = this._tileAt(this.pos)
    if (current) current.setAttribute("tabindex", "-1")
    this.pos = pos
    const next = this._tileAt(pos)
    if (!next) return
    next.setAttribute("tabindex", "0")
    next.focus({ preventScroll: false })
  },

  /**
   * Tab trap, pattern copied from `hooks/sheet.js` (:32-40) — the PATTERN, not
   * the hook. Attaching `Sheet` itself would install a second Escape handler
   * beside the picker root's existing `phx-window-keydown`, and it reads
   * `data-open` / `data-on-close` / `data-on-close-target` this element does not
   * carry.
   */
  _trapTab(e) {
    if (!this.panel) return
    const focusable = Array.from(
      this.panel.querySelectorAll(
        'button:not([tabindex="-1"]):not([hidden]), [href], input, select, textarea, [tabindex="0"]'
      )
    ).filter((el) => el.offsetParent !== null || el === document.activeElement)
    if (focusable.length === 0) return

    const first = focusable[0]
    const last = focusable[focusable.length - 1]

    // On open, focus sits on the PANEL, which is `tabindex="-1"` and therefore
    // not in `focusable`. Neither boundary branch below would fire, and
    // Shift+Tab would walk straight out of the dialog into the page behind it.
    if (!focusable.includes(document.activeElement)) {
      e.preventDefault()
      ;(e.shiftKey ? last : first).focus()
      return
    }

    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault()
      first.focus()
    }
  },

  // ── breakpoint changes ───────────────────────────────────────────────────

  /**
   * Rebuild the `role="row"` wrappers ONLY when the visual column count has
   * actually changed. A resize that does not cross a breakpoint must not
   * rebuild ~1,850 nodes, and on mobile `resize` fires for the URL bar
   * collapsing during a scroll, not only for a real reflow.
   *
   * The CHROME is MOVED rather than rebuilt: the search field holds the user's
   * text and possibly the caret, and re-creating it across a rotation would
   * discard both.
   */
  _onResize() {
    if (this.state !== "ready" && this.state !== "error") return
    if (this.resizeFrame) return
    this.resizeFrame = requestAnimationFrame(() => {
      this.resizeFrame = null
      if (!this.scrollEl || !this.inventoryEl) return

      this._placeChrome()

      const grid = this.scrollEl.querySelector(".reaction-picker-grid")
      if (!grid) return
      const columns = countColumns(getComputedStyle(grid).gridTemplateColumns)
      if (columns === 0 || columns === this.columns) return

      this.columns = columns
      this._rebuildRows()
    })
  },

  _rebuildRows() {
    this.inventoryRows = []
    for (const section of this.sections) {
      const wrap = this.inventoryEl.querySelector(
        `.reaction-picker-section[data-category="${CSS.escape(section.slug)}"]`
      )
      const grid = wrap && wrap.querySelector(".reaction-picker-grid")
      if (!grid) continue
      grid.textContent = ""
      for (const tiles of fillGrid(document, grid, section.entries, this.columns)) {
        this.inventoryRows.push(tiles)
      }
    }

    if (this.searching) this._paintResults(this.searchInput ? this.searchInput.value : "")
    this._afterRowsRebuilt()
  },
}

export default ReactionPicker
