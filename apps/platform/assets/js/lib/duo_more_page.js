/**
 * DuoMorePage — on the OPEN iPhone Duo, More is a page (`/more`), not the
 * bottom sheet (task 01a1fc7f stage 2).
 *
 * WHY: the More sheet is a fixed overlay outside the main pane. A tab tap is
 * instant only for `main[data-scroll-container]` (tab_switch_cache.js swaps
 * it on the click frame), so an open sheet stayed over the next tab until
 * the destination mounted, then played its slide-down. A page inside main is
 * exited by that same swap. PlatformWeb.MoreLive renders the sheet's own rows
 * at `/more`.
 *
 * POSTURE GATE, read at CLICK time: only while <html> carries BOTH
 * `data-native-duo` (native, iPhone Duo only) AND `data-native-duo-open`
 * (native, while the Duo is unfolded; flips live on fold, task 01a1fc7f
 * stage 1). Without both the listener returns at once and touches nothing,
 * so the closed Duo, every other iPhone and every browser keep the sheet.
 * Because the attributes are read per click, a fold flips the behaviour
 * live with no `burrowNativeDuoPosture` listener: there is no cached state
 * for that event to refresh.
 *
 * WHAT IT CATCHES, in a window CAPTURE-phase click listener (so it runs
 * before LiveView's phx-click and nav_pending.js):
 *   - the More tab, `#bottom-nav button[data-destination="more"]` (native
 *     More taps arrive as `tab.click()` from native_tab_bar.js handleTab);
 *   - any `[phx-click="open_more_sheet"]` (Settings' header Back, the Inbox
 *     and Files roots' "Back to More").
 * It calls preventDefault + stopImmediatePropagation, so LiveView never sends
 * `open_more_sheet`, then navigates to `/more` through the LiveSocket
 * (`liveSocket.js().navigate`). On `/more` already (a More reselect) it
 * scrolls the page to the top instead. Tapping More inside Settings or below
 * pops to `/more`.
 */

export const DUO_ATTR = "data-native-duo"
export const DUO_OPEN_ATTR = "data-native-duo-open"
export const MORE_PATH = "/more"
export const MORE_SELECTOR = '#bottom-nav button[data-destination="more"], [phx-click="open_more_sheet"]'
export const PAGE_SCROLLER_SELECTOR = "#more-page"

export function openDuo(doc) {
  const root = doc?.documentElement
  if (!root?.hasAttribute) return false
  return root.hasAttribute(DUO_ATTR) && root.hasAttribute(DUO_OPEN_ATTR)
}

function closestMatch(target, selector) {
  if (!target) return null
  if (typeof target.closest === "function") return target.closest(selector)
  return null
}

function scrollToTop(win, doc) {
  const page = doc.querySelector?.(PAGE_SCROLLER_SELECTOR)
  const main = doc.querySelector?.("main[data-scroll-container]")
  const reduced = win?.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches === true
  for (const el of [page, main]) {
    if (el && typeof el.scrollTo === "function") el.scrollTo({top: 0, behavior: reduced ? "auto" : "smooth"})
  }
}

/**
 * Installs the listener. `getLiveSocket` is called at click time (app.js
 * installs this before it constructs the LiveSocket). Returns an uninstall
 * function (tests).
 */
export function installDuoMorePage(win, doc, getLiveSocket) {
  if (!win?.addEventListener || !doc) return () => {}

  const onClick = (e) => {
    if (!openDuo(doc)) return
    const control = closestMatch(e.target, MORE_SELECTOR)
    if (!control) return

    e.preventDefault()
    e.stopImmediatePropagation()

    const path = win.location?.pathname
    if (path === MORE_PATH) {
      scrollToTop(win, doc)
      return
    }

    const socket = typeof getLiveSocket === "function" ? getLiveSocket() : null
    const js = socket && typeof socket.js === "function" ? socket.js() : null
    if (js && typeof js.navigate === "function") {
      js.navigate(MORE_PATH)
    } else if (win.location) {
      win.location.assign(MORE_PATH)
    }
  }

  win.addEventListener("click", onClick, true)
  return () => win.removeEventListener("click", onClick, true)
}

export default installDuoMorePage
