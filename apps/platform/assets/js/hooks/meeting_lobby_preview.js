import { ACTIVE_DEVICE_EVENT, preferredDeviceId } from "../lib/media_devices"

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
 *
 * ## Which camera (task 01a1f4c5 stage 1)
 *
 * The preview opens the person's remembered camera
 * (`media_devices.preferredDeviceId("videoinput")`, NON-exact so a missing
 * camera falls back instead of failing), and re-acquires when
 * `meeting:active-device` reports a new `videoinput` — a pick in the lobby's
 * device panel persists the choice and the preview follows it. The Room built
 * at Join reads the same preference, so what the lobby shows is what joins.
 */
const MeetingLobbyPreview = {
  mounted() {
    this._stream = null
    this._onActiveDevice = (event) => {
      const detail = (event && event.detail) || {}
      if (detail.kind !== "videoinput") return
      this._restart()
    }
    if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
      window.addEventListener(ACTIVE_DEVICE_EVENT, this._onActiveDevice)
    }
    this._sync()
  },

  updated() {
    this._sync()
  },

  destroyed() {
    if (typeof window !== "undefined" && typeof window.removeEventListener === "function") {
      window.removeEventListener(ACTIVE_DEVICE_EVENT, this._onActiveDevice)
    }
    this._stop()
  },

  // The camera changed: drop the current stream and open the new one. A
  // capture still pending is superseded: `_start` stops any stream that
  // resolves for an older generation.
  _restart() {
    if (!this._wantCamera()) return
    if (this._stream) {
      this._stream.getTracks().forEach((t) => t.stop())
      this._stream = null
    }
    this._pending = false
    this._start()
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
    const gen = (this._gen = (this._gen || 0) + 1)
    const deviceId = preferredDeviceId("videoinput")
    const constraint = deviceId ? { deviceId } : true

    Promise.resolve()
      .then(() => media.getUserMedia({ video: constraint, audio: false }))
      .then((stream) => {
        // A newer `_start` (a camera switch) superseded this one.
        if (gen !== this._gen) {
          stream.getTracks().forEach((t) => t.stop())
          return
        }
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
        if (gen !== this._gen) return
        this._pending = false
        this.el.dataset.preview = "unavailable"
        console.warn("[MeetingLobbyPreview] camera preview unavailable:", err)
      })
  },

  _stop() {
    // Any capture still in flight is now stale.
    this._gen = (this._gen || 0) + 1
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
