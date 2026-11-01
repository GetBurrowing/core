/**
 * ThemePicker hook — the utility bar's preset and mode picker (task 01a1557a,
 * Burrow redesign 2, stage 4). It replaces the ThemeToggle hook in place.
 *
 * Component: lib/platform_web/components/theme_picker.ex. The hook element is
 * the picker body, rendered once in the lg popover and once in the mobile
 * sheet; both instances follow the same `burrow:theme` event.
 *
 * Drives `window.burrowTheme`, the API the root layout's
 * `data-role="theme-boot"` script exposes (stage 3). The boot script owns the
 * `burrow-theme-v1` cache, the `<html>` attributes and the theme-color meta.
 * This hook:
 *   - on select, calls `window.burrowTheme.apply({preset, mode})` straight
 *     away (no server round trip), then pushes `set_theme` so ShellLive
 *     stores the choice for the next load on any device;
 *   - owns the checked state (`aria-checked`, roving `tabindex`, the check
 *     icon) and every chip's `data-theme`. The body is `phx-update="ignore"`,
 *     so a LiveView patch cannot reset them;
 *   - repaints on `burrow:theme`, which also fires for another tab and for an
 *     OS scheme change under "system".
 *
 * Saving (task 01a19555 stage 3). `set_theme` and `clear_theme` reply
 * `{ok}`. On `ok: false` (the write was refused) the hook re-applies the
 * PREVIOUS {preset, mode} through `window.burrowTheme.apply`, repaints the
 * checked row and unhides `[data-role="theme-save-error"]`. "Use install
 * default" (`[data-role="theme-use-install-default"]`) applies the install
 * default the boot script carries (`data-default-preset` /
 * `data-default-mode`) and pushes `clear_theme`. Whether a choice is stored
 * is shared by every instance through `burrow:theme-stored`, so the popover
 * and the sheet show the button alike.
 *
 * Keyboard (both groups are role="radiogroup"): ArrowDown / ArrowRight move
 * focus to the next option, ArrowUp / ArrowLeft to the previous one (both
 * wrap), Home / End to the ends; Enter or Space applies the focused option.
 *
 * Expected DOM inside the hook element:
 *   [data-theme-group="mode"|"preset"]          role="radiogroup"
 *     [data-theme-option="mode"|"preset"][data-value]   role="radio"
 *       [data-theme-chip]    (preset rows only) data-preset + data-theme
 *       [data-theme-check]   (preset rows only) hidden with `invisible`
 */

const NEXT_KEYS = new Set(["ArrowDown", "ArrowRight"])
const PREV_KEYS = new Set(["ArrowUp", "ArrowLeft"])
const APPLY_KEYS = new Set(["Enter", " ", "Spacebar"])

const optionsIn = (root, group) =>
  Array.from(root.querySelectorAll(`[data-theme-option="${group}"]`))

const optionOf = (target) =>
  target && typeof target.closest === "function" ? target.closest("[data-theme-option]") : null

const USE_DEFAULT = '[data-role="theme-use-install-default"]'
const SAVE_ERROR = '[data-role="theme-save-error"]'

const useDefaultOf = (target) =>
  target && typeof target.closest === "function" ? target.closest(USE_DEFAULT) : null

// The install default, as the root layout's theme-boot script carries it.
export const installDefault = (doc = document) => {
  const boot = doc && typeof doc.querySelector === "function"
    ? doc.querySelector('[data-role="theme-boot"]')
    : null
  const get = (name) => (boot ? boot.getAttribute(name) : null)
  return {preset: get("data-default-preset") || "burrow", mode: get("data-default-mode") || "dark"}
}

const setHidden = (el, hidden) => {
  if (!el) return
  if (hidden) el.setAttribute("hidden", "")
  else el.removeAttribute("hidden")
}

// The theme the boot script resolved, or the <html> attributes when the API
// is missing (it never is in the app; this keeps the hook inert, not broken).
export const currentTheme = () => {
  const api = typeof window !== "undefined" && window.burrowTheme
  const snapshot = api && typeof api.get === "function" ? api.get() : null
  if (snapshot) return snapshot

  const root = document.documentElement
  const resolved = root.getAttribute("data-theme") || "dark"
  return {preset: root.getAttribute("data-preset") || "burrow", mode: resolved, resolved}
}

// An org preset published after this page loaded has no CSS in the root
// layout's <style id="org-themes"> (it renders on a full load only) and is
// not in the boot script's registry, so `apply` would refuse it (task
// 01a1557a stage 5). ShellLive answers `set_theme` for an org preset with
// `burrow:org-theme` {preset, css}: CSS rendered and re-sanitised server-side
// by Platform.Theming.OrgThemeCss. This appends it to #org-themes as TEXT
// (never markup), registers the id, and applies it. A preset that is already
// registered already has its CSS on the page, so nothing is appended.
// Returns true when it injected.
export const ORG_PRESET = /^org-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

export const injectOrgTheme = (payload, doc = document, api = window.burrowTheme) => {
  const preset = payload && payload.preset
  const css = payload && payload.css
  if (typeof preset !== "string" || !ORG_PRESET.test(preset)) return false
  if (typeof css !== "string" || !css.includes(`[data-preset="${preset}"]`)) return false
  if (!api || typeof api.has !== "function" || typeof api.register !== "function") return false
  if (api.has(preset)) return false

  let style = doc.getElementById("org-themes")
  if (!style) {
    style = doc.createElement("style")
    style.setAttribute("id", "org-themes")
    style.setAttribute("data-role", "org-themes")
    doc.head.appendChild(style)
  }
  style.appendChild(doc.createTextNode(`\n${css}`))

  if (!api.register(preset)) return false
  const current = currentTheme()
  if (typeof api.apply === "function") api.apply({preset, mode: current.mode})
  return true
}

const ThemePicker = {
  mounted() {
    this.paint(currentTheme())

    if (typeof this.handleEvent === "function") {
      this.handleEvent("burrow:org-theme", (payload) => injectOrgTheme(payload))
    }

    this.handleTheme = (event) => this.paint((event && event.detail) || currentTheme())
    window.addEventListener("burrow:theme", this.handleTheme)

    this.handleStored = (event) => this.showStored(Boolean(event && event.detail && event.detail.stored))
    window.addEventListener("burrow:theme-stored", this.handleStored)

    this.handleClick = (event) => {
      const useDefault = useDefaultOf(event.target)
      if (useDefault && this.el.contains(useDefault)) {
        this.useInstallDefault()
        return
      }

      const option = optionOf(event.target)
      if (option && this.el.contains(option)) this.select(option)
    }

    this.handleKeydown = (event) => {
      const option = optionOf(event.target)
      if (!option || !this.el.contains(option)) return

      if (APPLY_KEYS.has(event.key)) {
        event.preventDefault()
        this.select(option)
      } else if (NEXT_KEYS.has(event.key)) {
        event.preventDefault()
        this.move(option, 1)
      } else if (PREV_KEYS.has(event.key)) {
        event.preventDefault()
        this.move(option, -1)
      } else if (event.key === "Home" || event.key === "End") {
        event.preventDefault()
        const group = optionsIn(this.el, option.dataset.themeOption)
        this.focus(event.key === "Home" ? group[0] : group[group.length - 1])
      }
    }

    this.el.addEventListener("click", this.handleClick)
    this.el.addEventListener("keydown", this.handleKeydown)
  },

  destroyed() {
    window.removeEventListener("burrow:theme", this.handleTheme)
    window.removeEventListener("burrow:theme-stored", this.handleStored)
  },

  // Applies first, so the page repaints with no server round trip, then
  // stores. The pushed pair is what the boot script actually applied.
  select(option) {
    const group = option.dataset.themeOption
    const value = option.dataset.value
    const current = currentTheme()
    const next = {preset: current.preset, mode: current.mode, [group]: value}

    const api = window.burrowTheme

    // A preset the page does not know yet (an org theme published after it
    // loaded): applying it here would be refused, so ask the server, which
    // stores it and sends its CSS back as `burrow:org-theme`.
    if (group === "preset" && api && typeof api.has === "function" && !api.has(value)) {
      this.focus(option)
      this.pushEvent("set_theme", {preset: value, mode: current.mode}, (reply) =>
        this.settled(reply, current, true)
      )
      return
    }

    const applied = api && typeof api.apply === "function" ? api.apply(next) : null
    const theme = applied || {...next, resolved: next.mode === "system" ? current.resolved : next.mode}

    this.paint(theme)
    this.focus(option)
    this.pushEvent("set_theme", {preset: theme.preset, mode: theme.mode}, (reply) =>
      this.settled(reply, current, true)
    )
  },

  // "Use install default": apply the boot script's default at once, then
  // ask the server to forget the stored choice.
  useInstallDefault() {
    const previous = currentTheme()
    const target = installDefault()
    const api = window.burrowTheme
    const applied = api && typeof api.apply === "function" ? api.apply(target) : null
    this.paint(applied || {...target, resolved: target.mode === "system" ? previous.resolved : target.mode})
    this.pushEvent("clear_theme", {}, (reply) => this.settled(reply, previous, false))
  },

  // The server's answer to a save. `ok: false` means nothing was written:
  // put the previous theme back and say so. Otherwise the error clears and
  // every instance learns whether a choice is now stored.
  settled(reply, previous, storedOnSuccess) {
    if (reply && reply.ok === false) {
      const api = window.burrowTheme
      const pref = {preset: previous.preset, mode: previous.mode}
      const applied = api && typeof api.apply === "function" ? api.apply(pref) : null
      this.paint(applied || previous)
      this.showError(true)
      return
    }

    this.showError(false)
    const detail = {stored: storedOnSuccess}
    if (typeof window.dispatchEvent === "function" && typeof CustomEvent === "function") {
      window.dispatchEvent(new CustomEvent("burrow:theme-stored", {detail}))
    } else {
      this.showStored(storedOnSuccess)
    }
  },

  showError(on) {
    setHidden(this.el.querySelector(SAVE_ERROR), !on)
  },

  showStored(stored) {
    setHidden(this.el.querySelector(USE_DEFAULT), !stored)
  },

  move(option, step) {
    const group = optionsIn(this.el, option.dataset.themeOption)
    const at = group.indexOf(option)
    if (at < 0 || group.length === 0) return
    this.focus(group[(at + step + group.length) % group.length])
  },

  focus(option) {
    if (option && typeof option.focus === "function") option.focus()
  },

  paint(theme) {
    if (!theme) return

    for (const group of ["mode", "preset"]) {
      for (const option of optionsIn(this.el, group)) {
        const active = option.dataset.value === theme[group]
        option.setAttribute("aria-checked", active ? "true" : "false")
        option.setAttribute("tabindex", active ? "0" : "-1")

        const check = option.querySelector("[data-theme-check]")
        if (check) check.classList.toggle("invisible", !active)
      }
    }

    // Each chip shows its own preset in the mode the page resolved to, so
    // "system" paints the chips in whatever the OS scheme currently is.
    for (const chip of this.el.querySelectorAll("[data-theme-chip]")) {
      chip.setAttribute("data-theme", theme.resolved)
    }
  },
}

export default ThemePicker
