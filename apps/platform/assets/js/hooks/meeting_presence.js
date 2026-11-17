// MeetingPresence hook (task 01a1e82a stage 2) on the shell's
// `#meeting-presence` element. It hands the call state the server renders
// there to the page-wide controller in ../meeting_presence.js and relays the
// server's `meeting_presence:toast` push_events. Every live navigation
// mounts a new LiveView, so `mounted()` is also how the controller learns a
// navigation kept the call.

import { installMeetingPresence, readState } from "../meeting_presence.js"

const MeetingPresence = {
  mounted() {
    this._presence = installMeetingPresence(window, document)
    this._api = {
      pushLeave: (done) => this.pushEvent("meeting_presence_leave", {}, (reply) => done(reply)),
      pushEnd: () => this.pushEvent("meeting_presence_end", {}),
      // Stage 3: the lock screen's Mute / camera when the top bar is not on
      // the page (the call room); the same events the bar's hook pushes.
      push: (event) => this.pushEvent(event, {}),
      navigate: (path) => {
        if (typeof this.js === "function") this.js().navigate(path)
        else window.location.assign(path)
      },
    }
    this._presence.mount(readState(this.el.dataset), this._api)
    this.handleEvent("meeting_presence:toast", (payload) => this._presence.onServerEvent(payload))
  },

  updated() {
    this._presence?.update(readState(this.el.dataset))
  },

  destroyed() {
    this._presence?.unmount(this._api)
  },
}

export default MeetingPresence
