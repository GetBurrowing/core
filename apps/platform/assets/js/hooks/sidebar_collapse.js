/**
 * SidebarCollapse hook — persists a LiveView's collapsed-state assign via
 * Suite.ClientState so the user's preference survives navigation between
 * modules and full-page reloads.
 *
 * Contract with the host LiveView:
 *   - On mount, read the stored collapsed flag. If a value exists and
 *     differs from the LV's current collapsed assign (advertised via the
 *     `data-collapsed` attribute on the hook element), push the
 *     `<hydrate_event>` event with `{collapsed: <bool>}` so the LV can
 *     rehydrate the assign from the stored preference.
 *   - Subscribe to LV-emitted `<change_event>` events (sent via
 *     `push_event` after every server-side toggle) and mirror the value
 *     into ClientState so subsequent navigations / reloads pick it up.
 *
 * Parameterization (task 019e40f2):
 *   The original implementation hard-coded a single set of constants for
 *   the shell sidebar. The hook is now parameterized via `data-*`
 *   attributes so the SAME module can drive N independent collapse panes
 *   (shell sidebar + meeting participant rail + meeting chat pane) each
 *   with their own namespaced storage key. Defaults preserve byte-
 *   identical behavior for the existing shell mount that doesn't set
 *   the new attributes.
 *
 *     data-storage-key    — sub-key under the `sidebar` namespace
 *                           (default: "suite.sidebar.collapsed")
 *     data-hydrate-event  — event pushed on mount when stored value differs
 *                           (default: "sidebar_hydrate")
 *     data-change-event   — event the LV pushes after a toggle
 *                           (default: "sidebar_collapsed_changed")
 *
 * No-value-in-storage = expanded (the LV's existing default).
 *
 * Task 019f3e9a stage 3: migrated off ad-hoc direct-store calls onto
 * `Suite.ClientState`. Any legacy raw entry under the un-namespaced storage
 * key is read once, migrated into the store, and deleted so the transition
 * is invisible to users.
 */
import ClientState from "../client_state.js";

const NAMESPACE = "sidebar";

const SidebarCollapse = {
  mounted() {
    const storageKey = this.el.dataset.storageKey || "suite.sidebar.collapsed";
    const hydrateEvent = this.el.dataset.hydrateEvent || "sidebar_hydrate";
    const changeEvent = this.el.dataset.changeEvent || "sidebar_collapsed_changed";

    let stored = ClientState.get(NAMESPACE, storageKey, null);
    if (stored === null) {
      // Legacy raw key: the un-namespaced value was the string "true" or
      // "false". Migrate once to a bool under ClientState and drop the raw
      // entry so subsequent mounts don't re-check it.
      try {
        const legacy = globalThis.localStorage?.getItem(storageKey); // client-state:allow (legacy migration)
        if (legacy !== null && legacy !== undefined) {
          stored = legacy === "true";
          ClientState.set(NAMESPACE, storageKey, stored);
          globalThis.localStorage.removeItem(storageKey); // client-state:allow (legacy migration)
        }
      } catch (_e) {
        // localStorage may be unavailable (private mode); no legacy value
        // to migrate — carry on.
      }
    }

    if (stored !== null) {
      const desired = stored === true || stored === "true";
      const currentAttr = this.el.getAttribute("data-collapsed");
      const current = currentAttr === "true";

      if (desired !== current) {
        this.pushEventTo(this.el, hydrateEvent, { collapsed: desired });
      }
    }

    this.handleEvent(changeEvent, ({ collapsed }) => {
      ClientState.set(NAMESPACE, storageKey, !!collapsed);
    });
  },
};

export default SidebarCollapse;
