/**
 * ModeToggle hook — the desktop sidebar's theme mode row, `#mode-toggle`
 * (Burrow redesign 22 stage 1; master-desktop.html L588).
 *
 * Component: lib/platform_web/components/sidebar.ex. One click flips the page
 * between light and dark through the theme picker's own path
 * (theme_picker.js): `window.burrowTheme.apply({preset, mode})` straight away,
 * then `set_theme`, which ShellLive stores. The preset is left as it is;
 * presets live in Settings > Appearance.
 *
 * The row names the mode a click turns ON: a dark page reads "Light mode"
 * with the crescent icon, a light page "Dark mode" with the sun. The server
 * paints the first frame from the stored preference and cannot resolve
 * "system", so the hook repaints from the page's resolved theme on mount,
 * after every patch, and on `burrow:theme` (another tab, an OS scheme change
 * under "system").
 *
 * Expected DOM inside the hook element:
 *   [data-mode-label]               the label text
 *   [data-mode-icon="dark"|"light"] the icon shown while the page is that mode
 */
import {currentTheme} from "./theme_picker"

export const labelFor = (resolved) => (resolved === "light" ? "Dark mode" : "Light mode")
export const nextMode = (resolved) => (resolved === "light" ? "dark" : "light")

const ModeToggle = {
  mounted() {
    this.paint(currentTheme())

    this.handleTheme = (event) => this.paint((event && event.detail) || currentTheme())
    window.addEventListener("burrow:theme", this.handleTheme)

    this.handleClick = (event) => {
      event.preventDefault()
      this.flip()
    }
    this.el.addEventListener("click", this.handleClick)
  },

  updated() {
    this.paint(currentTheme())
  },

  destroyed() {
    window.removeEventListener("burrow:theme", this.handleTheme)
  },

  flip() {
    const current = currentTheme()
    const next = {preset: current.preset, mode: nextMode(current.resolved || current.mode)}

    const api = window.burrowTheme
    const applied = api && typeof api.apply === "function" ? api.apply(next) : null
    const theme = applied || {...next, resolved: next.mode}

    this.paint(theme)
    this.pushEvent("set_theme", {preset: theme.preset, mode: theme.mode})
  },

  paint(theme) {
    if (!theme) return
    const resolved = theme.resolved === "light" ? "light" : "dark"

    this.el.setAttribute("data-resolved", resolved)

    const label = this.el.querySelector("[data-mode-label]")
    if (label) label.textContent = labelFor(resolved)

    for (const icon of this.el.querySelectorAll("[data-mode-icon]")) {
      icon.classList.toggle("hidden", icon.getAttribute("data-mode-icon") !== resolved)
    }
  },
}

export default ModeToggle
