// VoiceContext — remembers the Voice tab's last context on this device
// (task 01a1557a-eab7 stage 2; the masters' `burrow-voice-ctx`).
//
// Storage goes through ClientState, ../client_state.js (the lint gate forbids direct
// localStorage), so the masters' key lives at `suite:voice:burrow-voice-ctx`.
//
//   - mounted(): if the device remembers a space id, push it ONCE as
//     `voice_restore_context`. The server checks it against the viewer's
//     spaces; a stale id comes back as `voice_ctx_saved` with id null.
//   - `voice_ctx_saved` {id}: the authoritative pick. A space id is stored,
//     null clears the key.

import ClientState from "../client_state.js";

export const NAMESPACE = "voice";
export const KEY = "burrow-voice-ctx";

const VoiceContext = {
  mounted() {
    this.handleEvent("voice_ctx_saved", ({ id }) => {
      if (id) ClientState.set(NAMESPACE, KEY, String(id));
      else ClientState.remove(NAMESPACE, KEY);
    });

    const stored = ClientState.get(NAMESPACE, KEY, null);
    if (stored && stored !== this.el.dataset.contextId) {
      this.pushEvent("voice_restore_context", { id: String(stored) });
    }
  },
};

export default VoiceContext;
