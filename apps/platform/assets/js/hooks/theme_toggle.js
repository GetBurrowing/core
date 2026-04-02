/**
 * ThemeToggle hook — client-side dark/light mode toggle.
 *
 * Works with the `phx:set-theme` + localStorage mechanism already established
 * in root.html.heex. No server round-trip needed; preference is persisted to
 * localStorage under the key `phx:theme`.
 *
 * Expected DOM structure on the hook element:
 *   <button phx-hook="ThemeToggle" ...>
 *     <span data-icon="sun"  ...></span>   <!-- shown in dark mode -->
 *     <span data-icon="moon" ...></span>   <!-- shown in light mode -->
 *   </button>
 */
const ThemeToggle = {
  mounted() {
    this.updateIcon();

    // Sync icon when the theme changes anywhere (this tab, another tab, or a
    // server-dispatched phx:set-theme event)
    this.handleStorage = () => this.updateIcon();
    this.handleThemeChanged = () => this.updateIcon();
    window.addEventListener("storage", this.handleStorage);
    window.addEventListener("app:theme-changed", this.handleThemeChanged);

    this.el.addEventListener("click", () => this.toggle());
  },

  destroyed() {
    window.removeEventListener("storage", this.handleStorage);
    window.removeEventListener("app:theme-changed", this.handleThemeChanged);
  },

  currentTheme() {
    return typeof window.getAppTheme === "function"
      ? window.getAppTheme()
      : (document.documentElement.getAttribute("data-theme") ||
          localStorage.getItem("phx:theme") ||
          "dark");
  },

  updateIcon() {
    const theme = this.currentTheme();
    const sunEl = this.el.querySelector("[data-icon='sun']");
    const moonEl = this.el.querySelector("[data-icon='moon']");
    if (sunEl && moonEl) {
      // Dark mode → show sun (click to go light); Light mode → show moon (click to go dark)
      sunEl.classList.toggle("hidden", theme !== "dark");
      moonEl.classList.toggle("hidden", theme === "dark");
    }
    this.el.setAttribute(
      "aria-label",
      theme === "dark" ? "Switch to light mode" : "Switch to dark mode"
    );
  },

  toggle() {
    const current = this.currentTheme();
    const next = this.currentTheme() === "dark" ? "light" : "dark";

    console.debug("[ThemeToggle] toggle requested", {
      current,
      next,
      htmlTheme: document.documentElement.getAttribute("data-theme"),
      storedTheme: localStorage.getItem("phx:theme"),
    });

    if (typeof window.setAppTheme === "function") {
      window.setAppTheme(next);
    } else {
      localStorage.setItem("phx:theme", next);
      document.documentElement.setAttribute("data-theme", next);
      if (typeof window.showThemeDebugPanel === "function") {
        window.showThemeDebugPanel(`fallback-toggle(${next})`);
      }
    }

    this.updateIcon();
  },
};

export default ThemeToggle;
