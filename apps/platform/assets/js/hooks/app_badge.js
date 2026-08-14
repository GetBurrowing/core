/**
 * AppBadge — mirrors the unread-inbox count onto the two markers a browser
 * will actually show the user when Suite is not the focused window
 * (task 019ffb7b stage 6).
 *
 * Two surfaces, because no single one covers both ways Suite is run:
 *
 *   1. Installed window (docked or not) — `navigator.setAppBadge(count)`
 *      paints the count on the app icon in the Dock / taskbar; zero calls
 *      `navigator.clearAppBadge()`. Chrome and Edge 81+ on desktop and
 *      Safari 16.4+ for iOS/iPadOS home-screen apps implement it; Firefox
 *      does not, and Chrome on Android does not (Android derives its own
 *      badge from unread notifications). Both methods are secure-context
 *      only and return Promises that reject with `NotAllowedError` (the
 *      notifications permission is not granted), `InvalidStateError` (the
 *      document is not fully active) or `SecurityError` (same-origin block).
 *      Every call therefore ends in `.catch(() => {})`: a rejected badge is
 *      cosmetic and must never surface as an unhandled rejection.
 *
 *   2. Plain browser tab — `setAppBadge` has no icon to mark, so an
 *      uninstalled tab gets nothing from it. That is a platform limit of
 *      the Badging API ("designed specifically for installed web
 *      applications", W3C), not a gap in this hook, and its absence in tab
 *      mode is not a bug to file. The tab-mode marker is a document-title
 *      prefix instead: `(3) Chat · …`, dropped at zero.
 *
 * Both are applied on every update. Detecting which mode we are in
 * (`display-mode: standalone`) would buy nothing: the title bar is not
 * rendered in a standalone window, so a prefix there is invisible rather
 * than wrong, and calling `setAppBadge` from a tab is a no-op rather than
 * an error.
 *
 * THE TITLE PREFIX IS NOT WRITE-ONCE. `<.live_title>` (root.html.heex)
 * re-assigns `document.title` from the server's `page_title` on every
 * LiveView navigation, which wipes anything JS put in front of it —
 * `chat_live.ex` alone assigns `page_title` in seven places, so this fires
 * constantly. The MutationObserver below re-applies the prefix after each
 * of those writes. `withBadgePrefix` strips any prefix already present
 * before adding one, so re-application can never stack `(3) (3) `.
 *
 * The count arrives by `push_event` from `PlatformWeb.ShellLive` (mount +
 * every inbox change). The hook never polls and holds no subscription of
 * its own.
 */

// A badge prefix written by this hook: "(3) " or the capped "(99+) ".
const BADGE_PREFIX_RE = /^\(\d+\+?\)\s+/

/**
 * Remove every leading badge prefix from a title. Loops rather than
 * replacing once so a title that somehow accumulated two prefixes still
 * comes back clean instead of shedding one per navigation.
 */
export function stripBadgePrefix(title) {
  if (typeof title !== "string") return ""
  let out = title
  while (BADGE_PREFIX_RE.test(out)) out = out.replace(BADGE_PREFIX_RE, "")
  return out
}

/**
 * The title this hook wants, given the browser's current title and the
 * badge label (`null`/`""` at zero). Always strips first, so calling it
 * with its own output is a fixed point — the property the MutationObserver
 * re-entrancy below depends on.
 */
export function withBadgePrefix(title, label) {
  const bare = stripBadgePrefix(title)
  if (typeof label !== "string" || label.length === 0) return bare
  return `(${label}) ${bare}`
}

const AppBadge = {
  mounted() {
    this.badgeCount = 0
    this.badgeLabel = null

    // Observe `document.head`, not the `<title>` node: LiveView patching may
    // replace the element wholesale, and an observer bound to the discarded
    // node would silently watch nothing from then on. `characterData` +
    // `subtree` catches the common case (its text node being rewritten),
    // `childList` catches the replacement case.
    this.titleObserver = new MutationObserver(() => this.applyTitle())
    if (document.head) {
      this.titleObserver.observe(document.head, {
        childList: true,
        characterData: true,
        subtree: true,
      })
    }

    this.handleEvent("app_badge", payload => this.onBadge(payload))
  },

  destroyed() {
    if (this.titleObserver) {
      this.titleObserver.disconnect()
      this.titleObserver = null
    }
  },

  onBadge(payload) {
    const count = payload && payload.count
    this.badgeCount = Number.isFinite(count) && count > 0 ? Math.trunc(count) : 0

    // `label` is the server's already-capped string ("99+" past 99), so the
    // Dock badge, the title prefix and the icon-rail pill share one cap.
    const label = payload && payload.label
    this.badgeLabel = typeof label === "string" && label.length > 0 ? label : null

    this.applyBadge()
    this.applyTitle()
  },

  applyBadge() {
    if (this.badgeCount > 0) {
      if (!("setAppBadge" in navigator)) return
      // Raw integer, not the capped label: setAppBadge takes a Number and
      // the platform does its own ">99" formatting.
      navigator.setAppBadge(this.badgeCount).catch(() => {})
    } else {
      if (!("clearAppBadge" in navigator)) return
      navigator.clearAppBadge().catch(() => {})
    }
  },

  applyTitle() {
    const next = withBadgePrefix(document.title, this.badgeLabel)
    // Writing `document.title` mutates the `<title>` text node, which
    // re-enters the observer that may have called us. The equality guard is
    // what terminates that loop: the second pass computes the same string,
    // writes nothing, and no further mutation is queued.
    if (document.title !== next) document.title = next
  },
}

export default AppBadge
