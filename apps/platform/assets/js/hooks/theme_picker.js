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

    this.handleClick = (event) => {
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
      this.pushEvent("set_theme", {preset: value, mode: current.mode})
      return
    }

    const applied = api && typeof api.apply === "function" ? api.apply(next) : null
    const theme = applied || {...next, resolved: next.mode === "system" ? current.resolved : next.mode}

    this.paint(theme)
    this.focus(option)
    this.pushEvent("set_theme", {preset: theme.preset, mode: theme.mode})
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
