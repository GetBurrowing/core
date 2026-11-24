import { RoomEvent } from "livekit-client"
import {
  activeRoom,
  announceActiveDevice,
  handleDevicesChanged,
  kindOfPublication,
  seedInUse,
  unregisterRoom,
} from "../lib/media_devices"
import { disconnectLiveKitRoom } from "../meeting_presence.js"

/**
 * MeetingBar hook — bridges the in-call top bar controls to the LiveKit Room instance.
 *
 * Reads initial mic/camera state from window.__livekitRoom.localParticipant,
 * handles toggle clicks via LiveKit SDK, disconnects on leave, and runs a
 * client-side m:ss (h:mm:ss) duration timer. Gracefully handles null room.
 */
/**
 * Elapsed call time as the top bar shows it (task 01a1e82a stage 1):
 * m:ss, then h:mm:ss past an hour ("12:04", "1:02:09").
 */
export function formatElapsed(totalSeconds) {
  const s = Math.max(0, Math.floor(totalSeconds))
  const hours = Math.floor(s / 3600)
  const minutes = Math.floor((s % 3600) / 60)
  const seconds = String(s % 60).padStart(2, "0")
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}`
    : `${minutes}:${seconds}`
}

// The local publication events that change what "Mic on" / "Cam off" should
// read (task 01a1e82a remediation). `room-connected` fires BEFORE the join
// publishes its tracks, so a read there sees mic and camera off; these are
// the moments the live state actually moves.
export const LOCAL_MEDIA_EVENTS = [
  RoomEvent.LocalTrackPublished,
  RoomEvent.LocalTrackUnpublished,
  RoomEvent.TrackMuted,
  RoomEvent.TrackUnmuted,
]

// The live mic / camera state of the local participant, or null with no room.
export function liveMediaState(room) {
  const lp = room && room.localParticipant
  if (!lp) return null
  return { mic: lp.isMicrophoneEnabled === true, camera: lp.isCameraEnabled === true }
}

// Call `onChange(room)` whenever the local participant's mic / camera state
// can have changed: on every room the page connects (window
// `livekit:room-connected`) and on each local publish / unpublish / mute /
// unmute in it. Remote mutes are ignored. Returns a stop function that takes
// every listener back off the room and the window.
export function watchLocalMedia(win, onChange) {
  let bound = null
  let handlers = []
  const currentRoom = () => win.__livekit_room || win.__livekitRoom || null

  const release = () => {
    if (bound && typeof bound.off === "function") {
      for (const [event, fn] of handlers) {
        try {
          bound.off(event, fn)
        } catch (_) {
          /* already gone */
        }
      }
    }
    bound = null
    handlers = []
  }

  const bind = (room) => {
    if (!room || bound === room || typeof room.on !== "function") return
    release()
    bound = room
    for (const event of LOCAL_MEDIA_EVENTS) {
      const fn = (_pub, participant) => {
        const lp = room.localParticipant
        // TrackMuted / TrackUnmuted fire for remote participants too.
        if (participant && lp && participant !== lp && participant.identity !== lp.identity) return
        onChange(room)
      }
      room.on(event, fn)
      handlers.push([event, fn])
    }
  }

  const onConnected = (e) => {
    const room = (e && e.detail && e.detail.room) || currentRoom()
    bind(room)
    if (room) onChange(room)
  }
  const onDisconnected = () => release()

  win.addEventListener("livekit:room-connected", onConnected)
  win.addEventListener("livekit:room-disconnected", onDisconnected)
  bind(currentRoom())

  return () => {
    release()
    win.removeEventListener("livekit:room-connected", onConnected)
    win.removeEventListener("livekit:room-disconnected", onDisconnected)
  }
}

// The native call owns media inside the iOS app when its meetings plugin is
// there (the same check MeetingClient's native hand-off makes).
export function nativeCallOwnsMedia(win) {
  try {
    if (!win.Capacitor?.isNativePlatform?.()) return false
    const plugins = win.Capacitor.Plugins
    return !!(plugins && (plugins.BurrowMeetings || plugins.SuiteMeetings))
  } catch (_) {
    return false
  }
}

// The bar's "Sound and video" controls (task 01a1f4c5 stage 4): the mic
// and camera carets, and the panel root `MeetingBarLive` renders beside the
// bar (`#<bar id>-devices`, found through `data-bar-devices`).
export const DEVICE_CARETS = "[data-bar-mic-devices], [data-bar-camera-devices]"

// Inside the iOS app the native call owns the microphone, camera and route
// (CallKit), and WKWebView cannot choose an output: the carets and the panel
// are hidden. The server already leaves them out when it knows the call is
// native (`@native`); this covers the page that learns it first.
export function hideDeviceControls(root, doc, win) {
  const hide = nativeCallOwnsMedia(win)
  const nodes = root && typeof root.querySelectorAll === "function" ? [...root.querySelectorAll(DEVICE_CARETS)] : []
  const panelId = root && root.getAttribute ? root.getAttribute("data-bar-devices") : null
  const panel = panelId && doc && typeof doc.getElementById === "function" ? doc.getElementById(panelId) : null
  if (panel) nodes.push(panel)
  for (const node of nodes) {
    if (hide) node.setAttribute("hidden", "")
    else node.removeAttribute("hidden")
  }
  return hide
}

// A device unplugged while the person is on a page with no call client
// (/calendar, /inbox): MeetingClient's own MediaDevicesChanged listener went
// with its element, so the bar moves the room to a working device and the
// panel's strap says so under the bar. Where a call client IS mounted
// (`#meeting-client`, the chat) it does this itself, so the bar stands back,
// checked at event time because the chat can mount after the bar.
export function watchRoomDevices(win, doc) {
  let bound = null
  let handlers = []
  const currentRoom = () => activeRoom("meeting") || win.__livekit_room || win.__livekitRoom || null
  const clientMounted = () =>
    !!(doc && typeof doc.getElementById === "function" && doc.getElementById("meeting-client"))

  const release = () => {
    if (bound && typeof bound.off === "function") {
      for (const [event, fn] of handlers) {
        try {
          bound.off(event, fn)
        } catch (_) {
          /* already gone */
        }
      }
    }
    bound = null
    handlers = []
  }

  const bind = (room) => {
    if (!room || bound === room || typeof room.on !== "function") return
    release()
    bound = room
    const onDevices = () => {
      if (clientMounted() || nativeCallOwnsMedia(win)) return
      handleDevicesChanged(room).catch((err) =>
        console.warn("[MeetingBar] device fallback failed", err && err.message),
      )
    }
    const onActive = (kind, deviceId) => {
      if (clientMounted()) return
      announceActiveDevice(kind, deviceId)
    }
    // What each kind is on before any ActiveDeviceChanged, so a later
    // unplug knows the device it lost (stage 5 round 2).
    const onPublished = (pub) => {
      const kind = kindOfPublication(pub)
      if (kind) seedInUse(room, { kinds: [kind] }).catch(() => {})
    }
    room.on(RoomEvent.MediaDevicesChanged, onDevices)
    room.on(RoomEvent.ActiveDeviceChanged, onActive)
    room.on(RoomEvent.LocalTrackPublished, onPublished)
    handlers = [
      [RoomEvent.MediaDevicesChanged, onDevices],
      [RoomEvent.ActiveDeviceChanged, onActive],
      [RoomEvent.LocalTrackPublished, onPublished],
    ]
    if (!nativeCallOwnsMedia(win)) seedInUse(room).catch(() => {})
  }

  const onConnected = (e) => bind((e && e.detail && e.detail.room) || currentRoom())
  const onDisconnected = () => release()
  win.addEventListener("livekit:room-connected", onConnected)
  win.addEventListener("livekit:room-disconnected", onDisconnected)
  bind(currentRoom())

  return () => {
    release()
    win.removeEventListener("livekit:room-connected", onConnected)
    win.removeEventListener("livekit:room-disconnected", onDisconnected)
  }
}

/**
 * Toggle the local mic or camera from the top bar (or the lock screen) on
 * whatever page the person is on (task 01a1e82a remediation round 2).
 *
 *   - Native call owns media (iOS app): `meeting_toggle_*` to the server,
 *     which asks the native call with `%{want}` and repaints only on the
 *     call's confirmed state. Unchanged.
 *   - The chat's call client is mounted (`#meeting-client`): the same
 *     `meeting_toggle_*` push, so MeetingHooks keeps the chat's committed
 *     media intent (`data-mic-enabled`, which the reconnect reconciler
 *     reads) in step while MeetingClient toggles this same room.
 *   - Any other page (/calendar, /inbox, …): no call client is mounted to
 *     take a `toggle-mic` push, so the bar toggles `window.__livekit_room`
 *     itself, exactly as MeetingClient would, then reports the CONFIRMED
 *     pair as `meeting_media_confirmed` so the shell's cache, MeetingState
 *     and the chat (if the person goes back) agree with the room.
 *
 * The chip is never set here: it follows the room's own TrackMuted /
 * TrackUnmuted events through `watchLocalMedia`.
 */
export async function toggleLocalMedia(kind, { win, doc, push }) {
  const camera = kind === "camera"
  if (nativeCallOwnsMedia(win)) {
    push(camera ? "meeting_toggle_camera" : "meeting_toggle_mic", {})
    return "native"
  }
  const callClient = doc && typeof doc.getElementById === "function" && doc.getElementById("meeting-client")
  if (callClient) {
    push(camera ? "meeting_toggle_camera" : "meeting_toggle_mic", {})
    return "client"
  }
  const room = win.__livekit_room || win.__livekitRoom || null
  const lp = room && room.localParticipant
  if (!lp) return "none"
  try {
    if (camera) await lp.setCameraEnabled(!lp.isCameraEnabled)
    else await lp.setMicrophoneEnabled(!lp.isMicrophoneEnabled)
  } catch (err) {
    console.warn(`[MeetingBar] ${camera ? "camera" : "mic"} toggle failed:`, err)
  }
  push("meeting_media_confirmed", {
    mic: lp.isMicrophoneEnabled === true,
    camera: lp.isCameraEnabled === true,
  })
  return "room"
}

const MeetingBar = {
  mounted() {
    this._syncState()
    this._startTimer()
    this._bindControls()

    // Re-read mic / camera on every local publish and mute change, not only
    // at mount and room-connected (task 01a1e82a remediation, finding 1).
    this._stopWatch = watchLocalMedia(window, () => this._syncState())
    this._stopDevices = watchRoomDevices(window, typeof document === "undefined" ? null : document)
    hideDeviceControls(this.el, typeof document === "undefined" ? null : document, window)

    this._onDisconnected = () => {
      // Route to the MeetingBarLive LiveComponent (this.el lives inside it),
      // not the parent ChatLive which doesn't care about mini-bar state.
      this.pushEventTo(this.el, "meeting_bar_state", { mic: false, camera: false, connected: false })
    }
    window.addEventListener("livekit:room-disconnected", this._onDisconnected)

    this._onConnected = () => this._syncState()
    window.addEventListener("livekit:room-connected", this._onConnected)

    this.handleEvent("meeting_bar_sync", () => this._syncState())
  },

  updated() {
    this._stopTimer()
    this._startTimer()
    this._bindControls()
    hideDeviceControls(this.el, typeof document === "undefined" ? null : document, window)
  },

  destroyed() {
    this._stopTimer()
    this._unbindControls()
    window.removeEventListener("livekit:room-disconnected", this._onDisconnected)
    window.removeEventListener("livekit:room-connected", this._onConnected)
    if (this._stopWatch) this._stopWatch()
    this._stopWatch = null
    if (this._stopDevices) this._stopDevices()
    this._stopDevices = null
  },

  _syncState() {
    const state = liveMediaState(window.__livekit_room || window.__livekitRoom)
    if (!state) return
    // Never deduplicated against the last push: the server can repaint the
    // bar in between (a `:meeting_media_state` from a dropped publication
    // during a reconnect), and the republish that follows must win.
    this.pushEventTo(this.el, "meeting_bar_state", { ...state, connected: true })
  },

  _bindControls() {
    this._unbindControls()

    // Task 01a1e82a remediation round 2: see `toggleLocalMedia`. On the
    // chat (and in the iOS app) this is still the `meeting_toggle_*` push to
    // the active LiveView; on every other page it toggles the real room.
    // `pushEvent` (NOT `pushEventTo`) targets the active LiveView. A click
    // while the previous toggle of the same kind is in flight is dropped,
    // so a double click cannot race two enables against each other.
    this._pending = this._pending || { mic: false, camera: false }
    const toggle = (kind) => {
      if (this._pending[kind]) return
      this._pending[kind] = true
      const done = () => {
        this._pending[kind] = false
      }
      toggleLocalMedia(kind, {
        win: window,
        doc: typeof document === "undefined" ? null : document,
        push: (event, payload) => this.pushEvent(event, payload),
      }).then(done, done)
    }
    this._micHandler = () => toggle("mic")
    this._cameraHandler = () => toggle("camera")

    // The one non-hook leave (task 01a20b3e stage 4): it disconnects (which
    // stops the local tracks) and nulls BOTH window pointers, so no later
    // mount finds the dead Room on window.__livekit_room.
    this._leaveHandler = () => {
      const room = window.__livekit_room || window.__livekitRoom
      if (!room) return
      disconnectLiveKitRoom(window)
      unregisterRoom(room)
    }

    const el = this.el
    el.querySelectorAll("[data-bar-mic]").forEach(btn =>
      btn.addEventListener("click", this._micHandler)
    )
    el.querySelectorAll("[data-bar-camera]").forEach(btn =>
      btn.addEventListener("click", this._cameraHandler)
    )
    el.querySelectorAll("[data-bar-leave]").forEach(btn =>
      btn.addEventListener("click", this._leaveHandler)
    )
  },

  _unbindControls() {
    if (this._micHandler) {
      this.el.querySelectorAll("[data-bar-mic]").forEach(btn =>
        btn.removeEventListener("click", this._micHandler)
      )
    }
    if (this._cameraHandler) {
      this.el.querySelectorAll("[data-bar-camera]").forEach(btn =>
        btn.removeEventListener("click", this._cameraHandler)
      )
    }
    if (this._leaveHandler) {
      this.el.querySelectorAll("[data-bar-leave]").forEach(btn =>
        btn.removeEventListener("click", this._leaveHandler)
      )
    }
  },

  _startTimer() {
    const startedAt = this.el.dataset.startedAt
    if (!startedAt) return
    this._startTime = new Date(startedAt).getTime()
    if (isNaN(this._startTime)) return
    this._tick()
    this._timerInterval = setInterval(() => this._tick(), 1000)
  },

  _stopTimer() {
    if (this._timerInterval) {
      clearInterval(this._timerInterval)
      this._timerInterval = null
    }
  },

  _tick() {
    const elapsed = Math.max(0, Math.floor((Date.now() - this._startTime) / 1000))
    const display = formatElapsed(elapsed)
    const timerEl = this.el.querySelector("[data-timer]")
    if (timerEl) timerEl.textContent = display
  },
}

export default MeetingBar
