/**
 * MeetingLobbyPreview — the self-preview tile on the pre-join lobby
 * (task 01a07410 / FE-17 stage 4).
 *
 * ## What it owns, and what it deliberately does not
 *
 * It owns ONE local `MediaStream` for the `<video>` inside `this.el`, and
 * nothing else. The mic and camera CHOICE lives on the server, in the
 * `:mic_enabled` / `:camera_enabled` assigns `MeetingHooks` already owns
 * for the in-call controls; this hook only reads that choice off
 * `data-camera-enabled` and starts or stops the preview to match. It never
 * pushes an event and never touches LiveKit — the room does not exist yet,
 * and the state that carries INTO the room travels on the join payload,
 * not through here. A second media-state store beside `meeting_hooks.ex`
 * is exactly what the stage forbids.
 *
 * The preview is video only. A mic preview would need a level meter to be
 * worth the permission prompt; the lobby's mic toggle is honoured by the
 * connect path (`meeting_client.js` `_join`), which is where it matters.
 *
 * ## Lifecycle
 *
 * `mounted` and `updated` both run `_sync`: camera on and no stream ->
 * `getUserMedia({ video: true })` into the `<video>`; camera off and a
 * stream -> stop every track and clear `srcObject`. `destroyed` stops the
 * stream, and so does `_join`'s hand-off: when the LiveView leaves the
 * lobby the element is removed and LiveView calls `destroyed`, so the
 * camera light does not stay on behind the call.
 *
 * `getUserMedia` refusal (no device, permission denied, insecure context)
 * is not an error the user can act on from here: the tile stamps
 * `data-preview="unavailable"` so the CSS can show the placeholder, and
 * the Join action stays enabled — the room may still grant media later.
 */
const MeetingLobbyPreview = {
  mounted() {
    this._stream = null
    this._sync()
  },

  updated() {
    this._sync()
  },

  destroyed() {
    this._stop()
  },

  _wantCamera() {
    return this.el.dataset.cameraEnabled === "true"
  },

  _video() {
    return this.el.querySelector("video")
  },

  _sync() {
    if (this._wantCamera()) {
      if (!this._stream && !this._pending) this._start()
    } else if (this._stream || this._pending) {
      this._stop()
    } else if (!this.el.dataset.preview) {
      this.el.dataset.preview = "off"
    }
  },

  _start() {
    const media = typeof navigator !== "undefined" && navigator.mediaDevices
    if (!media || typeof media.getUserMedia !== "function") {
      this.el.dataset.preview = "unavailable"
      return
    }

    this._pending = true
    this.el.dataset.preview = "starting"

    Promise.resolve()
      .then(() => media.getUserMedia({ video: true, audio: false }))
      .then((stream) => {
        this._pending = false
        // The toggle flipped back to off while the prompt was up.
        if (!this._wantCamera()) {
          stream.getTracks().forEach((t) => t.stop())
          this.el.dataset.preview = "off"
          return
        }
        this._stream = stream
        const video = this._video()
        if (video) {
          video.srcObject = stream
          if (typeof video.play === "function") {
            Promise.resolve(video.play()).catch(() => {})
          }
        }
        this.el.dataset.preview = "live"
      })
      .catch((err) => {
        this._pending = false
        this.el.dataset.preview = "unavailable"
        console.warn("[MeetingLobbyPreview] camera preview unavailable:", err)
      })
  },

  _stop() {
    if (this._stream) {
      this._stream.getTracks().forEach((t) => t.stop())
      this._stream = null
    }
    this._pending = false
    const video = this._video()
    if (video) video.srcObject = null
    this.el.dataset.preview = "off"
  },
}

export default MeetingLobbyPreview
