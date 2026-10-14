import { toggleScreenShare } from "./lib/screen_share_policy"

/**
 * MeetingShareButton hook — toggles screen-share with the click gesture
 * preserved end-to-end (task 019e420f stage 2).
 *
 * Why this exists: `getDisplayMedia()` (which the shared `toggleScreenShare()` helper calls) is gated by the browser's "user activation" flag —
 * the API only succeeds while the call stack is rooted in a user gesture
 * (click, keydown, etc.). The previous wiring routed the click through
 * `phx-click="meeting_toggle_screen_share"`, which pushed a `toggle-screen-
 * share` event back to the browser on a server round-trip; by the time the
 * push_event landed, the user-activation had expired and the browser
 * silently denied the permission prompt with `NotAllowedError`.
 *
 * This hook binds the click client-side, calls
 * `toggleScreenShare(room)` synchronously inside
 * the click handler, then pushes a `meeting_screen_share_state` event to
 * mirror the new state to the server (for the button's tinted "sharing"
 * treatment).
 *
 * Fallback: when there's no LiveKit room (user hasn't joined the call
 * yet), the hook pushes the existing `meeting_toggle_screen_share` event
 * so the legacy server-driven path still gets a chance to no-op cleanly.
 */
const MeetingShareButton = {
  mounted() {
    this._onClick = (event) => this._handleClick(event)
    this.el.addEventListener("click", this._onClick)
  },

  destroyed() {
    if (this._onClick) this.el.removeEventListener("click", this._onClick)
  },

  async _handleClick(event) {
    // Pre-empt Phoenix's own click handler: if the element also has a
    // phx-click, it would fire AFTER us and double-toggle. We strip the
    // attribute on the server side, but defend-in-depth.
    event.preventDefault?.()
    event.stopPropagation?.()

    const room = window.__livekit_room || window.__livekitRoom

    if (!room || !room.localParticipant) {
      // No room → fall back to the legacy server event so the meeting
      // bar / chat surface can decide what to do (typically a flash
      // telling the user to join first).
      this.pushEvent("meeting_toggle_screen_share", {})
      return
    }

    try {
      // CRITICAL: this MUST run inside the click handler (no awaited
      // server round-trip first). The browser's user-activation flag is
      // gone the moment we yield to the WebSocket. See the moduledoc.
      await toggleScreenShare(room)

      const nowEnabled = !!room.localParticipant.isScreenShareEnabled
      this.pushEvent("meeting_screen_share_state", { enabled: nowEnabled })
    } catch (err) {
      console.warn("[MeetingShareButton] screen-share toggle failed:", err)
      // Mirror the *actual* state back to the server so the button
      // doesn't lie about what's happening on the wire.
      const truth = !!room.localParticipant.isScreenShareEnabled
      this.pushEvent("meeting_screen_share_state", { enabled: truth })
    }
  },
}

export default MeetingShareButton
