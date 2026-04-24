import { RoomEvent } from "livekit-client"

// Key → soundId. Display label shown in the popover + toast.
const SOUNDS = [
  { key: "1", id: "gong",     label: "Gong" },
  { key: "2", id: "airhorn",  label: "Air horn" },
  { key: "3", id: "applause", label: "Applause" },
  { key: "4", id: "crickets", label: "Crickets" },
  { key: "5", id: "faahh",    label: "Faahh" },
  { key: "6", id: "shocked",  label: "Shocked" },
  { key: "7", id: "suspense", label: "Suspense" },
]

const SOUND_BY_KEY = new Map(SOUNDS.map((s) => [s.key, s]))
const SOUND_BY_ID  = new Map(SOUNDS.map((s) => [s.id, s]))

const DATA_TOPIC   = "soundboard"
const SCHEMA_VER   = 1
const MESSAGE_TYPE = "soundboard:play"
const MUTE_KEY     = "suite:soundboard:muted"

const MAX_CONCURRENT_NODES = 32
const PLAY_SAFETY_MS       = 10000
const TOAST_VISIBLE_MS     = 2500
const TOAST_REMOVE_MS      = 3000

const INPUT_SELECTOR = 'input, textarea, select, [contenteditable=""], [contenteditable="true"]'

const MeetingSoundboard = {
  mounted() {
    this._room = null
    this._waitingForRoom = false
    this._roomListener = null
    this._audio = {}          // soundId -> preloaded HTMLAudioElement
    this._activeNodes = new Set()
    this._textDecoder = new TextDecoder()
    this._textEncoder = new TextEncoder()

    this._boundOnData   = this._onData.bind(this)
    this._boundOnKey    = this._onKey.bind(this)
    this._boundOnMuteToggle = this._onMuteToggle.bind(this)

    this._preloadAudio()
    this._syncMuteCheckboxes()
    this._attachMuteListeners()
    window.addEventListener("keydown", this._boundOnKey)

    this._tryBind()
  },

  destroyed() {
    window.removeEventListener("keydown", this._boundOnKey)
    if (this._roomListener) {
      document.removeEventListener("livekit:room-connected", this._roomListener)
      this._roomListener = null
    }
    this._detachMuteListeners()
    this._unbind()
    for (const node of this._activeNodes) {
      try { node.pause() } catch (_) {}
    }
    this._activeNodes.clear()
  },

  // ── Room binding (MeetingRoom sibling pattern) ───────────────────────

  _tryBind() {
    const room = window.__livekit_room || window.__livekitRoom
    if (!room) {
      if (!this._waitingForRoom) {
        this._waitingForRoom = true
        this._roomListener = (e) => {
          this._waitingForRoom = false
          if (e.detail && e.detail.room) {
            window.__livekit_room = e.detail.room
          }
          this._tryBind()
        }
        document.addEventListener("livekit:room-connected", this._roomListener, { once: true })
      }
      return
    }

    if (this._room === room) return
    this._unbind()
    this._room = room

    try {
      room.on(RoomEvent.DataReceived, this._boundOnData)
    } catch (e) {
      console.warn("[MeetingSoundboard] failed to subscribe to data channel:", e)
    }
  },

  _unbind() {
    if (this._room) {
      try { this._room.off(RoomEvent.DataReceived, this._boundOnData) } catch (_) {}
      this._room = null
    }
  },

  // ── Audio preload + playback ─────────────────────────────────────────

  _preloadAudio() {
    for (const { id } of SOUNDS) {
      const audio = new Audio(`/audio/soundboard/${this._fileFor(id)}`)
      audio.preload = "auto"
      this._audio[id] = audio
    }
  },

  _fileFor(soundId) {
    const idx = SOUNDS.findIndex((s) => s.id === soundId)
    return idx >= 0 ? `${idx + 1}-${soundId}.mp3` : null
  },

  _play(soundId) {
    const template = this._audio[soundId]
    if (!template) return

    if (this._activeNodes.size >= MAX_CONCURRENT_NODES) return

    const node = template.cloneNode()
    this._activeNodes.add(node)

    const cleanup = () => {
      this._activeNodes.delete(node)
      try { node.src = "" } catch (_) {}
    }

    node.addEventListener("ended", cleanup, { once: true })
    const safety = setTimeout(() => {
      try { node.pause() } catch (_) {}
      cleanup()
    }, PLAY_SAFETY_MS)
    node.addEventListener("ended", () => clearTimeout(safety), { once: true })

    node.play().catch((err) => {
      console.warn("[MeetingSoundboard] audio.play rejected:", err)
      clearTimeout(safety)
      cleanup()
    })
  },

  // ── Keyboard input ───────────────────────────────────────────────────

  _onKey(event) {
    if (event.isComposing) return
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return

    const sound = SOUND_BY_KEY.get(event.key)
    if (!sound) return

    const active = document.activeElement
    if (active && active.matches && active.matches(INPUT_SELECTOR)) return

    event.preventDefault()
    this._triggerLocal(sound.id)
  },

  _triggerLocal(soundId) {
    // Sender hears their own sound, no self-toast (by design).
    this._play(soundId)
    this._publish(soundId)
  },

  // ── Data channel send/receive ────────────────────────────────────────

  _publish(soundId) {
    const room = this._room
    if (!room || !room.localParticipant) {
      console.debug("[MeetingSoundboard] skipped publish: no room/localParticipant yet")
      return
    }

    const payload = {
      v: SCHEMA_VER,
      type: MESSAGE_TYPE,
      soundId,
      sender: {
        identity: room.localParticipant.identity,
        name: room.localParticipant.name || room.localParticipant.identity,
      },
      ts: Date.now(),
    }

    try {
      const bytes = this._textEncoder.encode(JSON.stringify(payload))
      room.localParticipant.publishData(bytes, { reliable: true, topic: DATA_TOPIC })
    } catch (e) {
      console.warn("[MeetingSoundboard] publishData failed:", e)
    }
  },

  _onData(payload, participant, _kind, topic) {
    if (topic !== DATA_TOPIC) return

    let msg
    try {
      msg = JSON.parse(this._textDecoder.decode(payload))
    } catch (_) {
      return
    }

    if (!msg || msg.v !== SCHEMA_VER || msg.type !== MESSAGE_TYPE) return
    const sound = SOUND_BY_ID.get(msg.soundId)
    if (!sound) return

    const senderIdentity = msg.sender?.identity || participant?.identity
    const localIdentity  = this._room?.localParticipant?.identity
    if (senderIdentity && localIdentity && senderIdentity === localIdentity) return

    const senderName =
      msg.sender?.name || participant?.name || participant?.identity || "Someone"

    // Toast always — mute only affects audio per product decision.
    this._showToast(senderName, sound.label)

    if (!this._isMuted()) {
      this._play(sound.id)
    }
  },

  // ── Mute state ───────────────────────────────────────────────────────

  _isMuted() {
    try { return localStorage.getItem(MUTE_KEY) === "true" } catch (_) { return false }
  },

  _setMuted(muted) {
    try { localStorage.setItem(MUTE_KEY, muted ? "true" : "false") } catch (_) {}
  },

  _muteCheckboxes() {
    return document.querySelectorAll("[data-soundboard-mute]")
  },

  _syncMuteCheckboxes() {
    const muted = this._isMuted()
    for (const box of this._muteCheckboxes()) box.checked = muted
  },

  _attachMuteListeners() {
    for (const box of this._muteCheckboxes()) {
      box.addEventListener("change", this._boundOnMuteToggle)
    }
  },

  _detachMuteListeners() {
    for (const box of this._muteCheckboxes()) {
      box.removeEventListener("change", this._boundOnMuteToggle)
    }
  },

  _onMuteToggle(event) {
    this._setMuted(event.target.checked)
    // Sync the other variant's checkbox (desktop + mobile popovers).
    this._syncMuteCheckboxes()
  },

  // ── Toast rendering ──────────────────────────────────────────────────

  _toastContainers() {
    return document.querySelectorAll("[data-soundboard-toasts]")
  },

  _showToast(senderName, soundLabel) {
    const containers = this._toastContainers()
    if (!containers.length) return

    const text = `${senderName} played ${soundLabel}`

    for (const container of containers) {
      const toast = document.createElement("div")
      toast.className =
        "pointer-events-none rounded-full bg-base-300/90 text-xs px-3 py-1 shadow transition-opacity duration-500 opacity-0"
      toast.textContent = text
      container.appendChild(toast)

      requestAnimationFrame(() => toast.classList.replace("opacity-0", "opacity-100"))

      setTimeout(() => toast.classList.replace("opacity-100", "opacity-0"), TOAST_VISIBLE_MS)
      setTimeout(() => toast.remove(), TOAST_REMOVE_MS)
    }
  },
}

export default MeetingSoundboard
