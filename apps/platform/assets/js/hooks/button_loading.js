// ButtonLoading
//
// Phoenix LiveView already applies `phx-click-loading` / `phx-submit-loading`
// classes to elements with `phx-click` / `phx-submit` while the round-trip is
// in flight. What LV does NOT do:
//
//   1. Delay-before-show: most Burrow operations resolve in < 100ms; flashing
//      a spinner for those feels worse than no feedback at all.
//   2. `aria-busy`: screen readers need an attribute, not a class, to announce
//      the loading state.
//
// This hook fills both gaps. Mount it on a <form> (covers all child submit
// buttons) or directly on a <button> with phx-click (covers itself).
//
// After 100ms of being in the loading class, `aria-busy="true"` is set on the
// target button(s). When the loading class is removed (response arrived or
// the timer hasn't fired yet), the pending timer is cancelled and aria-busy
// is cleared, preventing spinner flicker on near-instant operations.
//
// PRESS-HOLD BUTTONS (task 01a166be-b5b9 stage 3, design canvas 01a167b0
// rule 5). Nav-shell and menu buttons (the More tab, the sidebar toggles,
// the sheet close, the task settings and create-menu triggers) carry the
// class `press-hold` instead of this hook: some live in templates whose
// markup may only change by class, and a hook needs an id per element.
// `installPressHold` below gives them the same contract from one
// document-level capture listener: a click on a `.press-hold` element
// watches that element alone, sets aria-busy after the same 100ms if it is
// still `phx-click-loading`, and clears it when the class comes off. The
// held pressed fill and the 60% label are CSS on `.phx-click-loading`
// (app.css "Rule 5"); nothing here changes the button's width.

export const LOADING_CLASSES = ["phx-click-loading", "phx-submit-loading"]
export const DEFAULT_DELAY_MS = 100
export const PRESS_HOLD_SELECTOR = ".press-hold"

export function isLoading(el) {
  return LOADING_CLASSES.some(cls => el.classList.contains(cls))
}

// One busy timer over a loading source element and the targets that get
// aria-busy. Shared by the hook and by press-hold buttons.
export function createBusySync({
  source,
  targets,
  delay = DEFAULT_DELAY_MS,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = t => clearTimeout(t),
}) {
  let timer = null
  return {
    sync() {
      if (isLoading(source)) {
        if (timer == null) {
          timer = setTimer(() => {
            timer = null
            if (isLoading(source)) targets().forEach(btn => btn.setAttribute("aria-busy", "true"))
          }, delay)
        }
        return true
      }
      if (timer != null) {
        clearTimer(timer)
        timer = null
      }
      targets().forEach(btn => btn.removeAttribute("aria-busy"))
      return false
    },
    cancel() {
      if (timer != null) clearTimer(timer)
      timer = null
    },
  }
}

export function installPressHold({
  win = window,
  selector = PRESS_HOLD_SELECTOR,
  delay = DEFAULT_DELAY_MS,
  setTimer = (fn, ms) => win.setTimeout(fn, ms),
  clearTimer = t => win.clearTimeout(t),
  createObserver = cb => new MutationObserver(cb),
} = {}) {
  const watching = new Map()

  function stop(el) {
    const w = watching.get(el)
    if (!w) return
    w.busy.cancel()
    w.observer.disconnect()
    el.removeAttribute("aria-busy")
    watching.delete(el)
  }

  function watch(el) {
    if (watching.has(el)) return
    const busy = createBusySync({source: el, targets: () => [el], delay, setTimer, clearTimer})
    let seenLoading = false
    const observer = createObserver(() => {
      if (busy.sync()) seenLoading = true
      else if (seenLoading) stop(el)
    })
    observer.observe(el, {attributes: true, attributeFilter: ["class"]})
    watching.set(el, {busy, observer})
    // LiveView adds the loading class in its own (bubble-phase) click
    // handler, after this capture listener. A click that never starts a
    // round trip (a JS-only command) leaves nothing to watch.
    setTimer(() => {
      if (isLoading(el)) {
        seenLoading = true
        busy.sync()
      } else if (!seenLoading) {
        stop(el)
      }
    }, 0)
  }

  const onClick = e => {
    const el = e.target && e.target.closest ? e.target.closest(selector) : null
    if (el) watch(el)
  }

  win.addEventListener("click", onClick, true)
  return {
    watching: () => watching,
    dispose() {
      for (const el of [...watching.keys()]) stop(el)
      win.removeEventListener("click", onClick, true)
    },
  }
}

export default {
  mounted() {
    this.delay = parseInt(this.el.dataset.busyDelay || DEFAULT_DELAY_MS, 10)
    this.busy = createBusySync({source: this.el, targets: () => this.targets(), delay: this.delay})
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.el, { attributes: true, attributeFilter: ["class"] })
    this.sync()
  },

  destroyed() {
    if (this.busy) this.busy.cancel()
    if (this.observer) this.observer.disconnect()
  },

  targets() {
    if (this.el.tagName === "FORM") {
      return Array.from(this.el.querySelectorAll("button[type='submit']"))
    }
    return [this.el]
  },

  isLoading() {
    return isLoading(this.el)
  },

  sync() {
    this.busy.sync()
  },
}
