// Reload guard for the LiveSocket (task 01a120be).
//
// phoenix_live_view 1.1 recovers from several failures by reloading the
// page: `LiveSocket.reloadWithJitter(view, log)` disconnects the socket and,
// 5–10 s later, calls `window.location.reload()` unless the view has
// reconnected by then. It is reached from
//
//   * `bindTopLevelEvents`: the socket closed with code 1000 while a main
//     view exists (a "heartbeat timeout" teardown closes with 1000 too);
//   * `View.onJoinError`: the main view's join failed while the socket is up;
//   * `View.pushWithReply`: a push timed out (the socket looked open but the
//     network was gone);
//   * `View.onClose` with a pending live link.
//
// A reload destroys the browser's `File` handles, so a large upload that was
// paused offline can never resume. While `isBusy()` says an upload is
// running, this guard swallows the reload instead: it does NOT disconnect
// (Phoenix's own reconnect and channel rejoin timers keep retrying), nudges
// the socket to reconnect if it is fully closed, and re-checks every
// `retryMs`. Once nothing is busy, a still-needed reload proceeds exactly as
// LiveView asked for it (the original method, same arguments). If the view
// recovered in the meantime, nothing happens.

export function installReloadGuard(liveSocket, opts = {}) {
  const isBusy = opts.isBusy || (() => false)
  const retryMs = opts.retryMs || 2000
  const setT = opts.setTimeout || ((fn, ms) => setTimeout(fn, ms))
  const clearT = opts.clearTimeout || ((t) => clearTimeout(t))
  const log = opts.log || ((...args) => console.warn(...args))

  const original = liveSocket.reloadWithJitter
  let deferred = null
  let timer = null

  const recovered = (view) =>
    !view ||
    (typeof view.isDestroyed === "function" && view.isDestroyed()) ||
    (typeof view.isConnected === "function" && view.isConnected())

  function nudgeReconnect() {
    const socket = typeof liveSocket.getSocket === "function" ? liveSocket.getSocket() : liveSocket.socket
    if (!socket || (typeof socket.isConnected === "function" && socket.isConnected())) return
    const state = typeof socket.connectionState === "function" ? socket.connectionState() : null
    if (state === "connecting") return
    if (socket.reconnectTimer && typeof socket.reconnectTimer.scheduleTimeout === "function") {
      socket.reconnectTimer.scheduleTimeout()
    } else if (typeof socket.connect === "function") {
      socket.connect()
    }
  }

  function schedule(ms) {
    if (timer != null) clearT(timer)
    timer = setT(tick, ms)
  }

  function tick() {
    timer = null
    if (!deferred) return
    const { view, args } = deferred
    if (recovered(view)) {
      deferred = null
      return
    }
    if (isBusy()) {
      nudgeReconnect()
      schedule(retryMs)
      return
    }
    deferred = null
    original.apply(liveSocket, args)
  }

  liveSocket.reloadWithJitter = function guardedReloadWithJitter(view, ...rest) {
    if (!isBusy()) return original.call(liveSocket, view, ...rest)
    if (!deferred) log("[large-upload] LiveView asked to reload the page; held while an upload is running")
    deferred = { view, args: [view, ...rest] }
    nudgeReconnect()
    schedule(retryMs)
  }

  return {
    // Re-check now (an upload just finished or failed).
    kick() {
      if (deferred) schedule(0)
    },
    pending() {
      return deferred != null
    },
    uninstall() {
      if (timer != null) clearT(timer)
      timer = null
      deferred = null
      liveSocket.reloadWithJitter = original
    },
  }
}
