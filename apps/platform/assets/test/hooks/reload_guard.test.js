import { describe, it, expect, beforeEach } from "vitest"
import { installReloadGuard } from "../../js/lib/reload_guard.js"

/**
 * The reload guard (task 01a120be): phoenix_live_view's
 * `LiveSocket.reloadWithJitter` reloads the page to recover from a lost
 * connection, which destroys the File of a large upload paused offline. A
 * fake liveSocket stands in for LiveView: `reloads` counts calls that reached
 * the ORIGINAL reloadWithJitter (which is what navigates).
 */

function fakeLiveSocket() {
  const socket = {
    connected: false,
    state: "closed",
    reconnects: 0,
    isConnected() {
      return this.connected
    },
    connectionState() {
      return this.state
    },
    reconnectTimer: {
      scheduleTimeout() {
        socket.reconnects += 1
      },
    },
  }
  const ls = {
    reloads: [],
    socket,
    getSocket() {
      return socket
    },
    reloadWithJitter(view, log) {
      this.reloads.push([view, log])
    },
  }
  return ls
}

function fakeView() {
  return {
    connected: false,
    destroyed: false,
    isConnected() {
      return this.connected
    },
    isDestroyed() {
      return this.destroyed
    },
  }
}

function fakeTimers() {
  const queue = []
  return {
    setTimeout: (fn, ms) => {
      const t = { fn, ms, cleared: false }
      queue.push(t)
      return t
    },
    clearTimeout: (t) => {
      if (t) t.cleared = true
    },
    // Run every pending timer once (timers they schedule wait for the next run).
    run() {
      const due = queue.splice(0)
      for (const t of due) if (!t.cleared) t.fn()
    },
    pending: () => queue.filter((t) => !t.cleared).length,
  }
}

describe("installReloadGuard", () => {
  let ls, timers, busy, guard
  beforeEach(() => {
    ls = fakeLiveSocket()
    timers = fakeTimers()
    busy = false
    guard = installReloadGuard(ls, {
      isBusy: () => busy,
      retryMs: 2000,
      setTimeout: timers.setTimeout,
      clearTimeout: timers.clearTimeout,
      log: () => {},
    })
  })

  it("passes a reload straight through when no upload is running", () => {
    const view = fakeView()
    ls.reloadWithJitter(view)
    expect(ls.reloads).toHaveLength(1)
    expect(ls.reloads[0][0]).toBe(view)
  })

  it("holds the reload while an upload is running and keeps retrying the connection", () => {
    busy = true
    const view = fakeView()
    ls.reloadWithJitter(view)
    expect(ls.reloads).toHaveLength(0)
    expect(guard.pending()).toBe(true)
    expect(ls.socket.reconnects).toBe(1)

    // 60 s offline: still no reload, still nudging the socket.
    for (let i = 0; i < 30; i++) timers.run()
    expect(ls.reloads).toHaveLength(0)
    expect(ls.socket.reconnects).toBeGreaterThan(10)
  })

  it("does not nudge a socket that is already reconnecting", () => {
    busy = true
    ls.socket.state = "connecting"
    ls.reloadWithJitter(fakeView())
    timers.run()
    expect(ls.socket.reconnects).toBe(0)
  })

  it("drops the held reload if the view reconnected", () => {
    busy = true
    const view = fakeView()
    ls.reloadWithJitter(view)
    view.connected = true
    busy = false
    timers.run()
    expect(ls.reloads).toHaveLength(0)
    expect(guard.pending()).toBe(false)
  })

  it("lets a still-needed reload proceed, with LiveView's arguments, once no upload is running", () => {
    busy = true
    const view = fakeView()
    const log = () => {}
    ls.reloadWithJitter(view, log)
    timers.run()
    expect(ls.reloads).toHaveLength(0)

    busy = false
    guard.kick()
    timers.run()
    expect(ls.reloads).toEqual([[view, log]])
    expect(guard.pending()).toBe(false)
  })

  it("uninstall restores LiveView's method", () => {
    guard.uninstall()
    busy = true
    ls.reloadWithJitter(fakeView())
    expect(ls.reloads).toHaveLength(1)
  })
})
