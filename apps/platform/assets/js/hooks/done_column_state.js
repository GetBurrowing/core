// DoneColumnState — remembers, per viewer, whether the /tasks Done column is
// expanded (task 01a13884 stage 3). The server owns
// the state (`:done_expanded?` on BoardComponent, collapsed by default) and
// this hook only replays and records it through Suite.ClientState.
//
// Storage contract:
//   namespace: "tasks_ui"
//   key:       "done_expanded"
//   value:     boolean
//
//   - On `mounted()`, a stored `true` that the rendered state does not
//     already match is replayed as `board_toggle_done` with
//     `{expanded: true}`, pushed to `#tasks-board` (a hook's pushEvent ignores
//     phx-target, so the component is named explicitly).
//   - The server pushes `done_column_changed` `{expanded}` on every change;
//     the hook writes that value, so Show and Hide are both remembered.
//
// Cleared storage reads as missing, which leaves the server default
// (collapsed) in place.

import ClientState from "../client_state.js"

export const NAMESPACE = "tasks_ui"
export const KEY = "done_expanded"

const DoneColumnState = {
  mounted() {
    this.handleEvent("done_column_changed", ({ expanded }) => {
      ClientState.set(NAMESPACE, KEY, expanded === true)
    })

    const stored = ClientState.get(NAMESPACE, KEY, null)
    if (stored === true && this.el.dataset.expanded !== "true") {
      this.pushEventTo("#tasks-board", "board_toggle_done", { expanded: true })
    }
  },
}

export default DoneColumnState
