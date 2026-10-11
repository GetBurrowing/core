import { describe, it, expect, beforeEach } from "vitest"
import {
  createReconnectEscalation,
  parseThresholds,
  DEFAULT_ATTEMPTS,
  DEFAULT_SECONDS,
} from "../../js/lib/reconnect_escalation.js"

/**
 * The reconnect escalation engine (task 01a12b10, "Quiet reconnect"). A
 * fake clock drives the injected timers: `advance(ms)` moves `now` forward
 * and runs every timer that falls due, in order. `states` records every
 * onState emission, so "never escalated" is a statement about the whole run.
 */

function fakeClock() {
  let t = 0
  let seq = 0
  const timers = []
  return {
    now: () => t,
    setTimeout: (fn, ms) => {
      const timer = { fn, at: t + ms, seq: seq++, cleared: false }
      timers.push(timer)
      return timer
    },
    clearTimeout: (timer) => {
      if (timer) timer.cleared = true
    },
    advance(ms) {
      const end = t + ms
      for (;;) {
        const due = timers
          .filter((x) => !x.cleared && x.at <= end)
          .sort((a, b) => a.at - b.at || a.seq - b.seq)[0]
        if (!due) break
        due.cleared = true
        t = due.at
        due.fn()
      }
      t = end
    },
    // A frozen page: the clock jumps and every timer that came due during
    // the freeze fires late, at the new time, in schedule order.
    jump(ms) {
      t += ms
      for (;;) {
        const due = timers
          .filter((x) => !x.cleared && x.at <= t)
          .sort((a, b) => a.at - b.at || a.seq - b.seq)[0]
        if (!due) break
        due.cleared = true
        due.fn()
      }
    },
  }
}

const VISIBLE = new Set(["reconnecting", "up_to_date", "escalated"])

describe("createReconnectEscalation", () => {
  let clock, states, online, hidden, engine

  function make(overrides = {}) {
    engine = createReconnectEscalation({
      attempts: 10,
      seconds: 10,
      isOnline: () => online,
      isHidden: () => hidden,
      now: clock.now,
      setTimeout: clock.setTimeout,
      clearTimeout: clock.clearTimeout,
      onState: (s) => states.push(s),
      ...overrides,
    })
    return engine
  }

  const names = () => states.map((s) => s.state)
  const visible = () => names().filter((n) => VISIBLE.has(n))

  beforeEach(() => {
    clock = fakeClock()
    states = []
    online = true
    hidden = false
  })

  it("a reconnect inside the threshold never escalates", () => {
    make()
    engine.socketLost("client")
    for (let i = 0; i < 9; i++) {
      clock.advance(500)
      engine.attemptFailed("client")
    }
    clock.advance(4000) // 8.5 s since the loss, 9 failures
    engine.recovered({ changed: true })
    clock.advance(2000)
    expect(names()).not.toContain("escalated")
    expect(visible()).toEqual(["reconnecting", "up_to_date"])
    expect(names().at(-1)).toBe("idle")
  })

  it("escalates by attempts before the time limit", () => {
    make({ seconds: 300 })
    engine.socketLost("client")
    clock.advance(400)
    for (let i = 0; i < 9; i++) engine.attemptFailed("client")
    expect(names()).not.toContain("escalated")
    engine.attemptFailed("client")
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
    expect(clock.now()).toBe(400)
  })

  it("escalates by seconds with zero failures", () => {
    make({ attempts: 100, seconds: 3 })
    engine.socketLost("client")
    clock.advance(2999)
    expect(names()).not.toContain("escalated")
    clock.advance(1)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
    expect(engine.getState().failures).toBe(0)
  })

  it("already offline at the loss goes red only after the 3 s offline grace", () => {
    online = false
    make()
    engine.socketLost("client")
    clock.advance(2999)
    expect(names()).not.toContain("escalated")
    clock.advance(1)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
    expect(clock.now()).toBe(3000)
  })

  it("an offline() event during reconnecting goes red 3 s later", () => {
    make()
    engine.socketLost("client")
    clock.advance(1000)
    expect(states.at(-1).state).toBe("reconnecting")
    engine.offline()
    clock.advance(2999)
    expect(states.at(-1).state).toBe("reconnecting")
    clock.advance(1)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
    expect(clock.now()).toBe(4000)
  })

  it("an app resume that reports offline for a moment never goes red", () => {
    // Phone brings the app back: offline event, socket drop, then online
    // and a rejoin about a second later (Rowan, 2026-10-11).
    make()
    online = false
    engine.offline()
    engine.socketClosed("client")
    clock.advance(800)
    online = true
    engine.online({ connected: false })
    engine.socketClosed("client")
    clock.advance(400)
    engine.recovered({ changed: true })
    clock.advance(2000)
    expect(names()).not.toContain("escalated")
    expect(visible()).toEqual(["reconnecting", "up_to_date"])
  })

  it("back online inside the grace resets the offline clock", () => {
    make({ attempts: 100, seconds: 300 })
    engine.offline()
    clock.advance(2500)
    engine.online({ connected: false })
    engine.offline()
    clock.advance(2999)
    expect(names()).not.toContain("escalated")
    clock.advance(1)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
  })

  it("a navigator.onLine flap without online() does not restart the offline clock", () => {
    make({ attempts: 100, seconds: 300 })
    online = false
    engine.socketLost("client")
    clock.advance(1500)
    online = true
    engine.socketClosed("client")
    online = false
    clock.advance(1500)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
    expect(clock.now()).toBe(3000)
  })

  it("offlineGraceMs is configurable", () => {
    make({ offlineGraceMs: 500 })
    engine.offline()
    clock.advance(500)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
  })

  it("a loss frozen in the background never goes red on resume", () => {
    // Chrome Android: the socket drops, the page freezes for two minutes,
    // and on resume the stale timers fire before the reconnect lands.
    make()
    engine.socketLost("client")
    clock.advance(500)
    clock.jump(120000)
    expect(names()).not.toContain("escalated")
    engine.socketClosed("client")
    clock.advance(800)
    engine.recovered({ changed: true })
    clock.advance(2000)
    expect(names()).not.toContain("escalated")
    expect(visible()).toEqual(["reconnecting", "up_to_date"])
  })

  it("after a freeze the full 10 s limit applies again from the resume", () => {
    make({ attempts: 100 })
    engine.socketLost("client")
    clock.advance(500)
    clock.jump(120000)
    const resumedAt = clock.now()
    clock.advance(9999 - 0)
    expect(names()).not.toContain("escalated")
    clock.advance(1)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
    expect(clock.now() - resumedAt).toBe(10000)
  })

  it("failures before a freeze do not count after it", () => {
    make({ attempts: 3, seconds: 300 })
    engine.socketLost("client")
    engine.socketClosed("client")
    engine.socketClosed("client")
    engine.socketClosed("client") // 2 failures
    clock.jump(60000)
    engine.socketClosed("client") // first close after the freeze
    expect(engine.getState().failures).toBe(1)
    expect(names()).not.toContain("escalated")
  })

  it("nothing escalates while hidden; resumed() restarts the clock", () => {
    make({ attempts: 100 })
    hidden = true
    engine.socketLost("client")
    clock.advance(60000)
    expect(names()).not.toContain("escalated")
    hidden = false
    engine.resumed()
    clock.advance(9999)
    expect(names()).not.toContain("escalated")
    clock.advance(1)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
  })

  it("offline while hidden goes red only 3 s after the resume", () => {
    make()
    hidden = true
    online = false
    engine.offline()
    clock.advance(30000)
    expect(names()).not.toContain("escalated")
    hidden = false
    engine.resumed()
    clock.advance(2999)
    expect(names()).not.toContain("escalated")
    clock.advance(1)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
  })

  it("resumed() while idle or escalated changes nothing", () => {
    make({ seconds: 1 })
    engine.resumed()
    expect(states).toEqual([])
    engine.socketLost("client")
    clock.advance(1000)
    expect(states.at(-1).state).toBe("escalated")
    engine.resumed()
    expect(states.at(-1).state).toBe("escalated")
  })

  it("a crash plus fast remount stays quiet", () => {
    make()
    engine.socketLost("server")
    clock.advance(1200)
    engine.recovered({ changed: true })
    clock.advance(2000)
    expect(names()).not.toContain("escalated")
    expect(visible()).toEqual(["reconnecting", "up_to_date"])
    expect(names().at(-1)).toBe("idle")
  })

  it("a sub-grace drop where nothing changed emits no visible state", () => {
    make()
    engine.socketLost("client")
    clock.advance(200)
    engine.recovered({ changed: false })
    clock.advance(20000)
    expect(visible()).toEqual([])
    expect(engine.getState().state).toBe("idle")
  })

  it("a sub-grace drop that remounted goes straight to up_to_date", () => {
    make()
    engine.socketLost("client")
    clock.advance(200)
    engine.recovered({ changed: true })
    expect(visible()).toEqual(["up_to_date"])
    clock.advance(1500)
    expect(names().at(-1)).toBe("idle")
  })

  it("a second drop during up_to_date replaces it and is not stacked", () => {
    make()
    engine.socketLost("client")
    clock.advance(500)
    engine.recovered({ changed: true })
    clock.advance(500)
    engine.socketLost("client")
    clock.advance(500)
    expect(states.at(-1).state).toBe("reconnecting")
    // The first up_to_date timer was cancelled: no idle sneaks in mid-loss.
    clock.advance(1000)
    expect(states.at(-1).state).toBe("reconnecting")
    engine.recovered({ changed: true })
    clock.advance(1500)
    expect(visible()).toEqual(["reconnecting", "up_to_date", "reconnecting", "up_to_date"])
    expect(names().filter((n) => n === "idle")).toHaveLength(1)
  })

  it("escalated then recovered goes to up_to_date, then idle", () => {
    make({ seconds: 2 })
    engine.socketLost("client")
    clock.advance(2000)
    expect(states.at(-1).state).toBe("escalated")
    engine.recovered({ changed: true })
    expect(states.at(-1).state).toBe("up_to_date")
    clock.advance(1500)
    expect(states.at(-1).state).toBe("idle")
  })

  it("recovered() resets the counters for the next loss", () => {
    make({ seconds: 300 })
    engine.socketLost("client")
    for (let i = 0; i < 9; i++) engine.attemptFailed("client")
    engine.recovered({ changed: false })
    engine.socketLost("client")
    engine.attemptFailed("client")
    expect(names()).not.toContain("escalated")
    expect(engine.getState().failures).toBe(1)
  })

  it("emits each state once per transition, not on every retry", () => {
    make()
    engine.socketLost("client")
    clock.advance(400)
    for (let i = 0; i < 5; i++) engine.attemptFailed("client")
    engine.socketLost("client")
    expect(visible()).toEqual(["reconnecting"])
  })

  it("a server escalation carries kind server", () => {
    make({ attempts: 2, seconds: 300 })
    engine.socketLost("server")
    engine.attemptFailed("server")
    engine.attemptFailed("server")
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "server" })
  })

  it("ignores recovered() while idle", () => {
    make()
    engine.recovered({ changed: true })
    expect(states).toEqual([])
  })

  it("an offline blip over a live socket recovers on online()", () => {
    make()
    engine.offline()
    clock.advance(3000)
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
    engine.online({ connected: true })
    expect(states.at(-1).state).toBe("up_to_date")
    clock.advance(1500)
    expect(names()).toEqual(["pending", "reconnecting", "escalated", "up_to_date", "idle"])
  })

  it("a short offline blip over a live socket stays quiet", () => {
    make()
    engine.offline()
    clock.advance(200)
    engine.online({ connected: true })
    clock.advance(2000)
    expect(visible()).toEqual([])
    expect(names().at(-1)).toBe("idle")
  })

  it("online() with the socket still down keeps the red until the rejoin", () => {
    make()
    engine.offline()
    clock.advance(3000)
    engine.online({ connected: false })
    engine.online()
    clock.advance(60000)
    expect(visible()).toEqual(["reconnecting", "escalated"])
    engine.recovered({ changed: false })
    clock.advance(1500)
    expect(visible()).toEqual(["reconnecting", "escalated", "up_to_date"])
    expect(names().at(-1)).toBe("idle")
  })

  it("online() while idle changes nothing", () => {
    make()
    engine.online({ connected: true })
    expect(states).toEqual([])
  })

  it("the drop's own close is not a failure; each later close is", () => {
    make({ attempts: 2, seconds: 300 })
    engine.socketLost("client") // onError before the drop's close
    engine.socketClosed("client") // the drop
    expect(engine.getState().failures).toBe(0)
    engine.socketClosed("client") // retry 1
    expect(engine.getState().failures).toBe(1)
    expect(names()).not.toContain("escalated")
    engine.socketClosed("client") // retry 2
    expect(states.at(-1)).toEqual({ state: "escalated", kind: "client" })
  })
})

// Phoenix 1.8.5 socket backoff, retry k waits SCHEDULE[k - 1] (see the module
// doc comment). Each retry here fails at once, as a refused connection does
// during a deploy restart: the socket closes at the instant the retry starts.
const SCHEDULE = [10, 50, 100, 150, 200, 250, 500, 1000, 2000]
const retryDelay = (k) => SCHEDULE[k - 1] || 5000

describe("the real Phoenix schedule with fast failures", () => {
  let clock, states, engine

  // Drop at t=0, then retries on the Phoenix schedule until untilMs.
  // Returns the time of the first escalation (or null) and the failure count
  // at that moment.
  function run(opts, untilMs) {
    clock = fakeClock()
    states = []
    let escalatedAt = null
    let failuresAt = null
    engine = createReconnectEscalation({
      ...opts,
      isOnline: () => true,
      now: clock.now,
      setTimeout: clock.setTimeout,
      clearTimeout: clock.clearTimeout,
      onState: (s) => {
        states.push(s)
        if (s.state === "escalated" && escalatedAt == null) {
          escalatedAt = clock.now()
          failuresAt = engine.getState().failures
        }
      },
    })
    engine.socketClosed("client") // the drop
    let t = 0
    for (let k = 1; ; k++) {
      t += retryDelay(k)
      if (t > untilMs) break
      clock.advance(t - clock.now())
      engine.socketClosed("client")
    }
    clock.advance(untilMs - clock.now())
    return { escalatedAt, failuresAt }
  }

  it("at the defaults, no red before 10 s and red at 10.0 s (seconds decides)", () => {
    const quiet = run({}, 9999)
    expect(quiet.escalatedAt).toBe(null)
    expect(engine.getState().failures).toBe(10) // retries 1..10, the 10th at 9260 ms

    const red = run({}, 20000)
    expect(red.escalatedAt).toBe(10000)
    expect(red.failuresAt).toBe(10)
  })

  it("attempts=3 goes red at the 3rd retry's close, 160 ms", () => {
    const r = run({ attempts: 3, seconds: 10 }, 20000)
    expect(r.escalatedAt).toBe(160)
    expect(r.failuresAt).toBe(3)
  })
})

describe("parseThresholds", () => {
  it("defaults to 11/10 when missing", () => {
    expect(DEFAULT_ATTEMPTS).toBe(11)
    expect(DEFAULT_SECONDS).toBe(10)
    expect(parseThresholds(undefined)).toEqual({ attempts: 11, seconds: 10 })
    expect(parseThresholds({})).toEqual({ attempts: 11, seconds: 10 })
  })

  it("reads decimal strings, as a meta dataset carries them", () => {
    expect(parseThresholds({ attempts: "3", seconds: "25" })).toEqual({ attempts: 3, seconds: 25 })
  })

  it("falls back on garbage, zero and negatives", () => {
    for (const bad of ["", "abc", "NaN", "0", "-4", "2.5", "1e3", null, NaN, 0, -1, 1.5]) {
      expect(parseThresholds({ attempts: bad, seconds: bad })).toEqual({ attempts: 11, seconds: 10 })
    }
  })

  it("clamps attempts to 1..100 and seconds to 1..300", () => {
    expect(parseThresholds({ attempts: "1000", seconds: "100000" })).toEqual({
      attempts: 100,
      seconds: 300,
    })
    expect(parseThresholds({ attempts: "1", seconds: "1" })).toEqual({ attempts: 1, seconds: 1 })
  })

  it("createReconnectEscalation applies the same normalisation", () => {
    expect(createReconnectEscalation({}).thresholds).toEqual({ attempts: 11, seconds: 10 })
    expect(createReconnectEscalation({ attempts: 0, seconds: 999 }).thresholds).toEqual({
      attempts: 11,
      seconds: 300,
    })
  })
})
