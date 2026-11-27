// VoiceContext — the Voice tab's choices remembered on this device: its last
// context (task 01a1557a-eab7 stage 2; the masters' `burrow-voice-ctx`) and,
// per user, its last voice partner (task 01a20dc5).
//
// Storage goes through ClientState, ../client_state.js (the lint gate forbids
// direct localStorage), under `suite:voice:<key>`. The server owns the keys
// and every decision; this hook only stores and reads back:
//
//   - `data-keys`: the space-separated keys to restore, rendered by VoiceLive.
//   - mounted() AND reconnected() push `voice_restore` {<key>: id, ...} with
//     whatever the device holds for those keys (nothing when it holds none).
//     A reconnect mounts a fresh VoiceLive on its defaults (Burrow, no
//     context), so it has to hear them again.
//   - `voice_saved` {key, id}: the authoritative pick. An id is stored, null
//     clears the key (the server's answer to a stale id).

import ClientState from "../client_state.js";

export const NAMESPACE = "voice";
export const KEY = "burrow-voice-ctx";

const VoiceContext = {
  mounted() {
    this.handleEvent("voice_saved", ({ key, id }) =>
      id ? ClientState.set(NAMESPACE, key, String(id)) : ClientState.remove(NAMESPACE, key),
    );
    this.reconnected();
  },

  reconnected() {
    const saved = {};
    for (const key of (this.el.dataset.keys || "").split(" ")) {
      const id = key && ClientState.get(NAMESPACE, key, null);
      if (id) saved[key] = String(id);
    }
    if (Object.keys(saved).length) this.pushEvent("voice_restore", saved);
  },
};

export default VoiceContext;
