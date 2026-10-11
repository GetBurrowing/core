/**
 * NativeInstallSwitch — the install switcher button in the shell's utility
 * bar (task 01a1261e stage 3).
 *
 * The server renders `#native-install-switch` with class `hidden` for every
 * client. This hook reveals it ONLY inside the Burrow app, and only on a
 * build whose SuiteNative plugin implements `installBadges`, so a browser,
 * a PWA and a shipped app build without the method all keep today's UI
 * exactly.
 *
 * BRIDGE CONTRACT (this stage owns it; the iOS and Android stages implement
 * it verbatim):
 *
 *   - `SuiteNative.installBadges()` resolves `{ others_unread: boolean }`:
 *     whether any signed-in install OTHER than the one showing has unread.
 *   - The native side fires the window event `burrowInstallBadges` (no
 *     payload) whenever that answer may have changed; the hook re-queries.
 *   - `SuiteNative.switchInstall()` opens the app's install picker.
 *
 * The dot is asked for on mount, when the page becomes visible again, and
 * on every `burrowInstallBadges`. Every plugin promise ends in a catch: a
 * rejected or malformed answer HIDES the dot. A stale "on" is worse than a
 * missed one, because the picker it points to would show nothing new.
 *
 * LiveView re-renders of the shell patch this element back to the server's
 * `hidden` classes, so `updated()` re-applies the revealed state and the
 * last known dot.
 */

const DOT_SELECTOR = "[data-role='install-unread-dot']"

// The SuiteNative plugin when the switcher may show, else null.
export function installBadgesPlugin(win = globalThis.window) {
  const cap = win?.Capacitor
  if (!cap?.isNativePlatform?.()) return null
  const plugin = cap.Plugins?.SuiteNative
  if (!plugin || typeof plugin.installBadges !== "function") return null
  return plugin
}

// Call a plugin method and always get a promise back, even when the method
// throws synchronously or returns a plain value.
function call(plugin, method) {
  try {
    return Promise.resolve(plugin[method]())
  } catch (error) {
    return Promise.reject(error)
  }
}

const NativeInstallSwitch = {
  mounted() {
    this.plugin = installBadgesPlugin()
    this.othersUnread = false
    if (!this.plugin) return

    this.reveal()

    this.onClick = () => {
      if (typeof this.plugin.switchInstall !== "function") return
      call(this.plugin, "switchInstall").catch(() => {})
    }

    this.onBadges = () => this.refresh()

    this.onVisibility = () => {
      if (document.visibilityState === "visible") this.refresh()
    }

    this.el.addEventListener("click", this.onClick)
    window.addEventListener("burrowInstallBadges", this.onBadges)
    document.addEventListener("visibilitychange", this.onVisibility)

    this.refresh()
  },

  updated() {
    if (!this.plugin) return
    this.reveal()
    this.paintDot()
  },

  destroyed() {
    if (!this.plugin) return
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("burrowInstallBadges", this.onBadges)
    document.removeEventListener("visibilitychange", this.onVisibility)
  },

  reveal() {
    this.el.classList.remove("hidden")
    this.el.classList.add("flex")
  },

  refresh() {
    // A later answer always wins over an earlier one still in flight.
    const seq = (this.seq = (this.seq || 0) + 1)

    call(this.plugin, "installBadges")
      .then(result => result?.others_unread === true)
      .catch(() => false)
      .then(on => {
        if (seq !== this.seq) return
        this.othersUnread = on
        this.paintDot()
      })
  },

  paintDot() {
    const dot = this.el.querySelector(DOT_SELECTOR)
    if (!dot) return
    if (this.othersUnread) dot.classList.remove("hidden")
    else dot.classList.add("hidden")
  }
}

export default NativeInstallSwitch
