// The Speaker button for the iOS app's native call.
//
// WKWebView has no `HTMLMediaElement.setSinkId` and no `audiooutput`
// devices, so a web output picker is inert inside the app. And the call's
// audio is not the page's: the native call (CallKit plus the LiveKit Swift
// SDK) plays it. So this button asks the native call through the
// `SuiteMeetings` plugin's `setSpeaker({on})`, and draws ONLY what the
// native call reports (`state().speaker`, `audioRouteChanged {speaker}`).
//
// The server renders the button `hidden` in native mode; it shows only when
// the build reports `capabilities().speaker === true`. An older build, or a
// browser, keeps it hidden. `hidden`, `aria-pressed` and `data-on` are owned
// here and kept off LiveView's patches (`JS.ignore_attributes` in
// `CallShell.call_controls/1`).

function nativeMeetings() {
  const plugins = window.Capacitor && window.Capacitor.Plugins
  return (plugins && (plugins.BurrowMeetings || plugins.SuiteMeetings)) || null
}

const MeetingSpeakerButton = {
  mounted() {
    this._onClick = (event) => {
      event.preventDefault()
      this._toggle()
    }
    this.el.addEventListener("click", this._onClick)
    this._ready = this._setup()
  },

  destroyed() {
    this._destroyed = true
    this.el.removeEventListener("click", this._onClick)
    const handle = this._routeHandle
    this._routeHandle = null
    if (handle) {
      Promise.resolve(handle)
        .then((h) => h && typeof h.remove === "function" && h.remove())
        .catch(() => {})
    }
  },

  async _setup() {
    const native = nativeMeetings()
    if (!native || typeof native.capabilities !== "function" || typeof native.setSpeaker !== "function") {
      return
    }
    let caps
    try {
      caps = (await native.capabilities()) || {}
    } catch (_error) {
      return
    }
    if (caps.speaker !== true || this._destroyed) return
    if (typeof native.addListener === "function") {
      this._routeHandle = native.addListener("audioRouteChanged", (data = {}) => {
        if (typeof data.speaker === "boolean") this._render(data.speaker)
      })
    }
    await this._readBack(native)
    if (this._destroyed) return
    this.el.hidden = false
  },

  async _readBack(native) {
    try {
      const state = (await native.state()) || {}
      if (typeof state.speaker === "boolean") this._render(state.speaker)
      else if (this.el.dataset.on === undefined) this._render(false)
    } catch (_error) {
      if (this.el.dataset.on === undefined) this._render(false)
    }
  },

  async _toggle() {
    const native = nativeMeetings()
    if (!native || typeof native.setSpeaker !== "function" || this._busy) return
    const want = this.el.dataset.on !== "true"
    this._busy = true
    this.el.setAttribute("aria-busy", "true")
    try {
      await native.setSpeaker({ on: want })
    } catch (error) {
      console.warn("[MeetingSpeakerButton] setSpeaker failed:", error && error.message)
    }
    // The preference is set; draw the OUTPUT the call reports (a headset
    // keeps the audio, and the button must not claim the speaker then).
    await this._readBack(native)
    this._busy = false
    this.el.removeAttribute("aria-busy")
  },

  _render(on) {
    this.el.dataset.on = String(on)
    this.el.setAttribute("aria-pressed", String(on))
    this.el.setAttribute("aria-label", on ? "Speaker on. Switch audio to the phone" : "Switch audio to the speaker")
  },
}

export default MeetingSpeakerButton
