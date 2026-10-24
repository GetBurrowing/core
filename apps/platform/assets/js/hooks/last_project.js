// LastProject — persists and restores the user's last-selected project on the
// /tasks board via Suite.ClientState. Stage 1 of task 019e031c.
//
// Storage contract:
//   namespace: "tasks_ui"
//   key:       "last_project_id"
//   sentinel:  "__all__" (server maps to selected_project_id: nil)
//   project:   raw UUID string
//
// The hook lives on the outermost /tasks wrapper, which contains both the
// desktop sidebar and the mobile sheet — so a single instance covers both
// selection sites.
//
// Persistence flow:
//   - On `mounted()`, read ClientState and push `sidebar_select_project` /
//     `filter_clear` to the server to restore the previous selection.
//   - The server emits a `selected_project_changed` event from the
//     `sidebar_select_project` (on SidebarComponent) and `filter_clear`
//     (on FiltersComponent) handlers (including the
//     stale-UUID fallback path that maps a missing UUID → nil). The hook
//     subscribes via `handleEvent` and writes the authoritative `id` to
//     ClientState. This is event-driven (not DOM-diff-driven) so a
//     fallback that doesn't change the rendered wrapper still triggers
//     the cleanup.
//   - We also keep a wrapper-attribute persistence pass (`updated()` +
//     mount-time `persistFromDom`) as a belt-and-braces fallback for any
//     state-change path that doesn't go through the two handlers above.
//
// Task 01a161fd stage 2: the server now remembers the project per USER in
// `users.preferences["tasks_project"]`. The restore push is skipped when the
// URL names a project (`?project=`) or when the server applied a stored
// preference (`data-project-source="pref"` on this wrapper), so a device's
// copy never overrides either. The ClientState writes stay: a device with no
// server preference still restores.
//
// Stage 5: the server now rewrites a bare /tasks entry in place to an explicit
// `?project=`, so every history entry carries its own selection. With nothing
// remembered it writes `?project=all` and marks the wrapper
// `data-project-source="default"`: that `project` is the server's default, not
// a choice, so the device copy is still replayed, through
// `tasks_restore_device_project`, which the server answers with a REPLACE
// patch to `?project=<id>` so the entry keeps naming what it shows. Not a
// client-side patch: the join applies its own replace AFTER hooks mount, and
// would overwrite it.
// parallel-ui: tasks.last_project_client_state
//
// Task 019f3e9a stage 3: migrated off ad-hoc direct-store calls onto
// `Suite.ClientState`. The legacy un-namespaced key
// `"suite:tasks-last-project-id"` is read once, ported into the store,
// and deleted so returning users don't lose their selection.

import ClientState from "../client_state.js";

const NAMESPACE = "tasks_ui";
const KEY = "last_project_id";
const LEGACY_KEY = "suite:tasks-last-project-id";
const ALL_PROJECTS_SENTINEL = "__all__";

// True when the server's choice must win over this device's stored copy.
function serverOwnsSelection(el) {
  const source = el?.dataset?.projectSource;
  if (source === "pref") return true;
  if (source === "default") return false;
  try {
    const search = globalThis.window?.location?.search || "";
    return new URLSearchParams(search).has("project");
  } catch (_e) {
    return false;
  }
}

function readStored() {
  let stored = ClientState.get(NAMESPACE, KEY, null);
  if (stored !== null) return stored;
  try {
    const legacy = globalThis.localStorage?.getItem(LEGACY_KEY); // client-state:allow (legacy migration)
    if (legacy == null) return null;
    ClientState.set(NAMESPACE, KEY, legacy);
    globalThis.localStorage.removeItem(LEGACY_KEY); // client-state:allow (legacy migration)
    return legacy;
  } catch (_e) {
    return null;
  }
}

const LastProject = {
  mounted() {
    // Subscribe to the server's authoritative selection event before pushing
    // anything — guarantees the response from the restore push lands in our
    // listener even if it arrives before the next mounted-callback tick.
    this.handleEvent("selected_project_changed", ({ id }) => {
      const value = id == null ? ALL_PROJECTS_SENTINEL : String(id);
      ClientState.set(NAMESPACE, KEY, value);
    });

    if (serverOwnsSelection(this.el)) {
      // The URL or the per-user preference decided; record it, push nothing.
      this.persistFromDom();
      return;
    }

    const stored = readStored();
    if (stored == null) {
      // First visit — record current state without pushing anything.
      this.persistFromDom();
      return;
    }

    const current = this.el.dataset.selectedProjectId || ALL_PROJECTS_SENTINEL;
    if (stored === current) {
      // Already in the desired state; nothing to do.
      return;
    }

    if (this.el.dataset.projectSource === "default") {
      // `?project=all` is already the screen; the server names the device's
      // project in place of it and selects it through handle_params.
      if (stored !== ALL_PROJECTS_SENTINEL) {
        this.pushEvent("tasks_restore_device_project", { id: stored });
      }
      return;
    }

    if (stored === ALL_PROJECTS_SENTINEL) {
      // pushEventTo, not pushEvent: `clear_filters` became `filter_clear`
      // on FiltersComponent in task 01a008f6 stage 6, and a hook's pushEvent
      // ignores phx-target.
      this.pushEventTo("#tasks-filters", "filter_clear", {});
    } else {
      this.pushEventTo("#tasks-sidebar", "sidebar_select_project", { id: stored });
    }
  },

  updated() {
    this.persistFromDom();
  },

  persistFromDom() {
    const value = this.el.dataset.selectedProjectId || ALL_PROJECTS_SENTINEL;
    ClientState.set(NAMESPACE, KEY, value);
  },
};

export { ALL_PROJECTS_SENTINEL, serverOwnsSelection };
export default LastProject;
