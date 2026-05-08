/**
 * SidebarCollapse hook — persists the shell sidebar's collapsed state in
 * localStorage so the user's preference survives navigation between modules
 * and full-page reloads.
 *
 * Contract with ShellLive:
 *   - On mount, read `suite.sidebar.collapsed` from localStorage. If a value
 *     exists and differs from the LV's current `:sidebar_collapsed` assign
 *     (advertised via the `data-collapsed` attribute on the hook element),
 *     push a `sidebar_hydrate` event with `{collapsed: <bool>}` so the LV
 *     can rehydrate.
 *   - Subscribe to LV-emitted `sidebar_collapsed_changed` events (sent via
 *     `push_event` after every server-side toggle) and mirror the value to
 *     localStorage so subsequent navigations / reloads pick it up.
 *
 * No-value-in-storage = expanded (the LV's existing default).
 */
const STORAGE_KEY = "suite.sidebar.collapsed";

const SidebarCollapse = {
  mounted() {
    const stored = localStorage.getItem(STORAGE_KEY);

    if (stored !== null) {
      const desired = stored === "true";
      const currentAttr = this.el.getAttribute("data-collapsed");
      const current = currentAttr === "true";

      if (desired !== current) {
        this.pushEventTo(this.el, "sidebar_hydrate", { collapsed: desired });
      }
    }

    this.handleEvent("sidebar_collapsed_changed", ({ collapsed }) => {
      try {
        localStorage.setItem(STORAGE_KEY, collapsed ? "true" : "false");
      } catch (_e) {
        // localStorage may be unavailable (private mode, quota); ignore.
      }
    });
  },
};

export default SidebarCollapse;
