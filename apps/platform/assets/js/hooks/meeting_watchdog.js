import { RoomEvent } from "livekit-client"

/**
 * MeetingWatchdog — shell-level LiveKit reconnect supervisor (task 019ee06b
 * stage 1, hardened in stage 2 v2).
 *
 * Background
 * ----------
 * `MeetingClient` (`meeting_client.js`) is mounted ONLY on /chat (quick-meet
 * panel) and /meetings (MeetingLive). The pinned `window.__livekitRoom`
 * survives navigation because the JS object isn't GC'd when the hook
 * destroys, BUT the `RoomEvent.Reconnecting` / `Reconnected` listeners on
 * the MeetingClient hook instance go away with `destroyed()` on the
 * MeetingClient surface — when the user navigates to /tasks (or any
 * non-meeting page) the room is orphan-supervised by LiveKit's internal
 * ICE-restart machinery, with no JS handler refreshing the watchdog's
 * `dataset.roomState` breadcrumb or producing a per-page observability
 * signal.
 *
 * The watchdog is a slim sibling of MeetingClient mounted on the shell
 * layout (stage 2 of this task) that ALWAYS supervises basic network-
 * survival concerns: reconnect breadcrumbs on its own element +
 * cross-hook `livekit:state` events tagged `source: "watchdog"`. No tile
 * rendering, no track attachment, no media-toggle handlers, no `_join` —
 * those remain owned by MeetingClient on the chat/meeting surfaces.
 *
 * Coordination with MeetingClient (v2 — stage 2 e2e fix)
 * ------------------------------------------------------
 * v1 used a `room.__watchdogBound` flag that MeetingClient SET and the
 * watchdog respected to "avoid double-bind." The e2e reviewer found the
 * flag was asymmetric (MeetingClient set but never checked) and the
 * watchdog's adopt path then early-returned without ever installing its
 * own listeners — so on /tasks after a WebSocket blip the watchdog's
 * `dataset.roomState` stayed at 'unknown' (case 1 FAIL), and across
 * navigation MeetingClient's listener count grew unbounded because
 * `_bindRoomEvents` was never gated and never cleaned up (case 3 FAIL).
 *
 * v2 removes the cross-hook flag entirely. Both hooks install their own
 * listeners on the Room, track refs for clean removal in `destroyed()`,
 * and use per-instance idempotency (`this._boundRoom`) so a re-adopt of
 * the same Room does not double-bind. The watchdog and MeetingClient
 * each fire their OWN breadcrumbs — they tag `source` on `livekit:state`
 * so downstream consumers can dedupe by origin, and they stamp DIFFERENT
 * dataset elements (`#meeting-watchdog.dataset.roomState` vs
 * `#meeting-client.dataset.roomState`) so neither overwrites the other.
 *
 * Singleton guard
 * ---------------
 * `window.__livekitWatchdogActive` still prevents two simultaneous
 * watchdog mounts (e.g. an LV repatch of the shell re-mounting the
 * element without destroying first). The flag is per-watchdog only —
 * it does NOT gate MeetingClient.
 *
 * NOT in this hook
 * ----------------
 * - `_join` / `_leave` / mic+camera+screenshare toggles (MeetingClient)
 * - tile rendering (`_ensureTile`, `_attachTrack`, `_attachLocalVideo` …)
 * - local self-view docking / mode-switch reparenting
 * - screen-share routing
 * - `_reconcileLocalMedia` (intent reconcile lives with MeetingClient — the
 *   watchdog never touches local media intent or device state)
 */

const MeetingWatchdog = {
  mounted() {
    // Singleton guard. If another watchdog instance is already supervising
    // (e.g. an LV repatch of the shell re-mounts the element), no-op so we
    // never double-bind the window-level page-exit listener or attempt a
    // duplicate room binding.
    if (typeof window !== "undefined" && window.__livekitWatchdogActive) {
      this._inactive = true
      return
    }
    if (typeof window !== "undefined") {
      window.__livekitWatchdogActive = true
    }

    // Per-instance bookkeeping for the Room we've adopted + the RoomEvent
    // listener refs we've installed (so destroyed() can remove them).
    this._boundRoom = null
    this._roomListeners = []

    // Page-exit teardown — mirrors MeetingClient lines 61-65. Disconnect the
    // room on a real navigation away (tab close, hard reload), not on an LV
    // repatch (those go through destroyed() without pagehide).
    this._onPageHide = () => {
      const room = this._currentRoom()
      if (room && typeof room.disconnect === "function") {
        try {
          room.disconnect()
        } catch (_) {
          /* already gone */
        }
      }
    }
    if (typeof window !== "undefined") {
      window.addEventListener("pagehide", this._onPageHide)
      window.addEventListener("beforeunload", this._onPageHide)
    }

    // Learn about NEW rooms born after the watchdog mounted (e.g. user on
    // /tasks when another tab pushed a join; or quick-meet started while the
    // shell was already up). MeetingClient dispatches these on both window
    // and document in _join (lines 422-423) and _cleanupRoom (lines 482-483).
    this._onRoomConnected = (evt) => {
      const room = (evt && evt.detail && evt.detail.room) || this._currentRoom()
      if (room) this._adoptRoom(room)
    }
    this._onRoomDisconnected = () => {
      // MeetingClient's _cleanupRoom already nulled window.__livekitRoom.
      // Drop our refs onto the (now disconnecting) room object so a future
      // adopt of a fresh Room starts from a clean state, and refresh the
      // breadcrumb so downstream observers see 'disconnected'.
      this._releaseRoom()
      this._emitState("disconnected", null)
    }
    if (typeof document !== "undefined") {
      document.addEventListener("livekit:room-connected", this._onRoomConnected)
      document.addEventListener("livekit:room-disconnected", this._onRoomDisconnected)
    }

    // Probe for an already-connected room on mount (the common path — the
    // shell repatches but the room survives because MeetingClient on
    // /chat/meetings established it). If `state === 'connected'`, attach
    // reconnect listeners idempotently.
    const existing = this._currentRoom()
    if (existing && existing.state === "connected") {
      this._adoptRoom(existing)
    }
  },

  destroyed() {
    if (this._inactive) return

    // Remove the listeners we installed on the Room so a subsequent
    // watchdog mount can take ownership without accumulating listeners.
    // The Room object survives (window.__livekitRoom) across our destroy/
    // re-mount cycle, so we MUST clean up explicitly — without this, every
    // shell repatch would leak a fresh listener set on the same Room.
    this._releaseRoom()

    if (typeof window !== "undefined") {
      window.removeEventListener("pagehide", this._onPageHide)
      window.removeEventListener("beforeunload", this._onPageHide)
      // Clear the singleton flag so a subsequent watchdog mount can take
      // ownership and re-install fresh listeners.
      window.__livekitWatchdogActive = false
    }
    if (typeof document !== "undefined") {
      document.removeEventListener("livekit:room-connected", this._onRoomConnected)
      document.removeEventListener("livekit:room-disconnected", this._onRoomDisconnected)
    }
  },

  // Read the canonical live Room reference. Both aliases are set by
  // MeetingClient._join (lines 420-421). MeetingClient also sets _room on
  // its hook instance, but we only have access via the window aliases.
  _currentRoom() {
    if (typeof window === "undefined") return null
    return window.__livekit_room || window.__livekitRoom || null
  },

  // Adopt a Room: install the watchdog-owned RoomEvent listeners (if not
  // already bound on THIS instance for THIS Room) and stamp the
  // dataset breadcrumb. Idempotent per-instance via `this._boundRoom`
  // (a re-adopt of the same Room re-stamps the breadcrumb but never
  // re-installs listeners), so MeetingClient setting its own listeners
  // on the same Room is irrelevant — we own ours, it owns its.
  _adoptRoom(room) {
    if (!room) return

    // Always refresh the breadcrumb so an adopt on an already-connected
    // room (no-op binding path) still surfaces the current state to e2e.
    this._emitState(room.state || "connected", room)

    if (this._boundRoom === room) return

    // If we previously bound to a DIFFERENT Room object (rare: leave +
    // re-join produces a brand-new Room), release the old refs first.
    if (this._boundRoom) this._releaseRoom()

    this._boundRoom = room
    this._roomListeners = []

    const bind = (event, fn) => {
      room.on(event, fn)
      this._roomListeners.push([event, fn])
    }

    bind(RoomEvent.Reconnecting, () => {
      this._emitState("reconnecting", room)
    })
    bind(RoomEvent.Reconnected, () => {
      this._emitState("reconnected", room)
    })
    bind(RoomEvent.ConnectionStateChanged, (state) => {
      // LiveKit also fires Reconnecting/Reconnected as discrete events; the
      // ConnectionStateChanged stream is a superset useful for unknown
      // transitions ("connecting", "signal-reconnecting"). We map only the
      // ones we want to surface as breadcrumbs — pass-through string state.
      if (typeof state === "string") {
        this._emitState(state, room)
      }
    })
    bind(RoomEvent.Disconnected, () => {
      this._emitState("disconnected", room)
    })
  },

  // Release any listeners we installed on the currently-bound Room. Safe
  // to call when no Room is bound — used by destroyed() and by the
  // livekit:room-disconnected handler when MeetingClient tore the Room
  // down out from under us.
  _releaseRoom() {
    const room = this._boundRoom
    if (room && typeof room.off === "function") {
      for (const [event, fn] of this._roomListeners) {
        try {
          room.off(event, fn)
        } catch (_) {
          /* listener may already be gone */
        }
      }
    }
    this._boundRoom = null
    this._roomListeners = []
  },

  // Set `dataset.roomState` on the watchdog element and dispatch a
  // `livekit:state` CustomEvent. Mirrors MeetingClient._emitState (lines
  // 515-530) so existing e2e selectors and observability surfaces keep
  // working — but never reads `room.localParticipant` (the watchdog doesn't
  // own publishing state) and tags `source: "watchdog"` so downstream
  // consumers can dedupe by origin when MeetingClient also fires.
  _emitState(state, room) {
    if (this.el && this.el.dataset) {
      this.el.dataset.roomState = state
    }
    const detail = {
      state,
      roomName: (room && room.name) || null,
      source: "watchdog",
    }
    if (typeof console !== "undefined" && console.info) {
      console.info("[MeetingWatchdog] state", state)
    }
    if (typeof document !== "undefined" && typeof CustomEvent !== "undefined") {
      document.dispatchEvent(new CustomEvent("livekit:state", { detail }))
    }
  },
}

export default MeetingWatchdog
