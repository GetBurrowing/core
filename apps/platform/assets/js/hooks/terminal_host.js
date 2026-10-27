// Thin hook for the remote terminal page. All the weight (xterm, WebCrypto,
// the socket) lives in js/terminal_island.js, loaded on demand; nothing of it
// is in app.js. The LiveView keeps the chrome, this hands it the host element.
import { loadTerminal } from "../lib/load_terminal"

const TerminalHost = {
  mounted() {
    this.destroyed_ = false
    loadTerminal()
      .then((api) => {
        if (this.destroyed_) return
        return api.mount({
          root: this.el,
          host: this.el.querySelector("#terminal-host"),
          runtimeId: this.el.dataset.runtimeId,
          pushEvent: (event, payload, cb) => this.pushEvent(event, payload, cb),
          handleEvent: (event, cb) => this.handleEvent(event, cb),
        })
      })
      .then((island) => {
        if (this.destroyed_) island?.destroy()
        else this.island = island
      })
      .catch(() => this.pushEvent("terminal_state", { state: "refused", reason: "load_failed" }))
  },

  destroyed() {
    this.destroyed_ = true
    this.island?.destroy()
  },
}

export default TerminalHost
