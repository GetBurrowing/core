import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"

/**
 * priv/prototype/suite.js, the bridge PrototypeController injects into every
 * prototype HTML response (task 01a1316b-84fa stage 2). It is a plain script,
 * not a module, so the test reads the very file the controller embeds and
 * runs it against a fake frame window whose `parent` records every post.
 */

const here = path.dirname(fileURLToPath(import.meta.url))
const SOURCE = readFileSync(path.join(here, "../../priv/prototype/suite.js"), "utf8")

function fakeTarget() {
  const listeners = {}
  return {
    posted: [],
    addEventListener(type, fn) {
      ;(listeners[type] ||= []).push(fn)
    },
    dispatch(type, event) {
      for (const fn of listeners[type] || []) fn(event)
    },
    postMessage(msg, target) {
      this.posted.push({ msg: JSON.parse(JSON.stringify(msg)), target })
    },
  }
}

function boot() {
  const parent = fakeTarget()
  const frame = fakeTarget()
  frame.parent = parent
  new Function("window", SOURCE)(frame)
  const fromParent = (data) => frame.dispatch("message", { source: parent, data })
  const sent = () => parent.posted.map((p) => p.msg)
  return { suite: frame.suite, frame, parent, fromParent, sent }
}

const snapshot = (seq, keys = {}, extra = {}) => ({
  suite: 1,
  type: "snapshot",
  seq,
  state: { keys, collections: {} },
  presence: [],
  me: { id: "u-1", display_name: "Alice" },
  ...extra,
})

const keyDiff = (seq, key, value, actor = "u-2") => ({
  suite: 1,
  type: "diff",
  seq,
  diff: { kind: "key", key, value },
  actor,
})

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

describe("suite.js start-up", () => {
  it("says hello to the parent with target * and becomes ready on the snapshot", async () => {
    const { suite, parent, fromParent } = boot()
    expect(parent.posted).toEqual([{ msg: { type: "hello", suite: 1 }, target: "*" }])
    expect(suite.connected).toBe(false)

    fromParent(snapshot(3, { count: 7 }))
    await expect(suite.ready).resolves.toBe(suite)
    expect(suite.connected).toBe(true)
    expect(suite.me).toEqual({ id: "u-1", display_name: "Alice" })
    expect(suite.state.get("count")).toBe(7)
  })

  it("binds window.burrow as the same object as window.suite (task 01a14b9e-50a4 stage 1)", async () => {
    const { suite, frame, fromParent } = boot()
    expect(frame.burrow).toBeDefined()
    expect(frame.burrow === frame.suite).toBe(true)

    fromParent(snapshot(1, { n: 2 }))
    await expect(frame.burrow.ready).resolves.toBe(suite)
    expect(frame.burrow.state.get("n")).toBe(2)
    expect(frame.suite.state.get("n")).toBe(2)
  })

  it("ignores messages from any source other than the parent", () => {
    const { suite, frame } = boot()
    frame.dispatch("message", { source: fakeTarget(), data: snapshot(1, { count: 99 }) })
    expect(suite.connected).toBe(false)
    expect(suite.state.get("count")).toBeUndefined()
  })
})

describe("suite.js mirror", () => {
  it("applies diffs in seq order and emits change events", () => {
    const { suite, fromParent } = boot()
    fromParent(snapshot(0))
    const changes = []
    suite.on("change", (ev) => changes.push(ev))

    fromParent(keyDiff(1, "count", 1))
    fromParent(keyDiff(2, "count", 2))
    fromParent(keyDiff(2, "count", 2)) // duplicate: ignored
    fromParent(keyDiff(1, "count", 1)) // stale: ignored

    expect(suite.state.get("count")).toBe(2)
    expect(changes.map((c) => [c.seq, c.kind, c.key, c.value, c.actor])).toEqual([
      [1, "key", "count", 1, "u-2"],
      [2, "key", "count", 2, "u-2"],
    ])
  })

  it("a seq gap sends hello and ignores diffs until a fresh snapshot", () => {
    const { suite, fromParent, sent } = boot()
    fromParent(snapshot(0))
    fromParent(keyDiff(1, "count", 1))
    fromParent(keyDiff(3, "count", 3)) // gap: seq 2 missing

    expect(sent().map((m) => m.type)).toEqual(["hello", "hello"])
    fromParent(keyDiff(4, "count", 4))
    expect(suite.state.get("count")).toBe(1)

    fromParent(snapshot(4, { count: 4 }))
    expect(suite.state.get("count")).toBe(4)
    fromParent(keyDiff(5, "count", 5))
    expect(suite.state.get("count")).toBe(5)
  })

  it("applies collection add, update and remove", () => {
    const { suite, fromParent } = boot()
    fromParent(snapshot(0))
    const col = (seq, op, id, item) => ({
      suite: 1,
      type: "diff",
      seq,
      diff: { kind: "collection", name: "cards", op, id, item },
      actor: "u-1",
    })

    fromParent(col(1, "add", "a", { id: "a", t: 1 }))
    fromParent(col(2, "add", "b", { id: "b", t: 2 }))
    fromParent(col(3, "update", "a", { id: "a", t: 9 }))
    fromParent(col(4, "remove", "b", null))

    expect(suite.collection("cards").list()).toEqual([{ id: "a", t: 9 }])
  })
})

describe("suite.js promises", () => {
  it("resolve on ack, and only once the mirror has reached the ack's seq", async () => {
    const { suite, fromParent, sent } = boot()
    fromParent(snapshot(0))

    let resolved = null
    suite.state.increment("count").then((v) => (resolved = v))
    const op = sent().at(-1)
    expect(op).toMatchObject({ type: "op", op: { type: "state.increment", key: "count", by: 1 } })

    // The ack beats its diff.
    fromParent({ suite: 1, type: "ack", req: op.req, ok: true, seq: 1, result: 1 })
    await Promise.resolve()
    expect(resolved).toBe(null)

    fromParent(keyDiff(1, "count", 1, "u-1"))
    await Promise.resolve()
    expect(resolved).toBe(1)
    expect(suite.state.get("count")).toBe(1)
  })

  it("reject with the server's error code", async () => {
    const { suite, fromParent, sent } = boot()
    fromParent(snapshot(0))
    const p = suite.state.set("label", "x")
    const op = sent().at(-1)
    fromParent({ suite: 1, type: "ack", req: op.req, ok: false, error: "rate_limited" })
    await expect(p).rejects.toThrow("rate_limited")
  })

  it("reject an op over the hook's 64 KB cap with too_large, without posting it", async () => {
    const { suite, fromParent, sent } = boot()
    fromParent(snapshot(0))
    const before = sent().length
    await expect(suite.state.set("big", "x".repeat(64 * 1024))).rejects.toThrow("too_large")
    expect(sent().length).toBe(before)

    // Under the cap it still posts: the check is on size, not on state.set.
    suite.state.set("ok", "x".repeat(60 * 1024))
    expect(sent().length).toBe(before + 1)
    expect(new TextEncoder().encode(JSON.stringify(sent().at(-1))).length).toBeLessThanOrEqual(64 * 1024)
  })

  it("reject with not_connected before any snapshot", async () => {
    const { suite } = boot()
    await expect(suite.state.set("label", "x")).rejects.toThrow("not_connected")
  })
})

describe("suite.js broadcast", () => {
  it("throttles each channel to one post per 34 ms, latest payload wins", () => {
    const { suite, fromParent, sent } = boot()
    fromParent(snapshot(0))
    const ephemeral = () => sent().filter((m) => m.type === "ephemeral")

    for (let x = 0; x < 10; x++) suite.broadcast("cursor", { x })
    expect(ephemeral()).toEqual([{ type: "ephemeral", channel: "cursor", payload: { x: 0 }, suite: 1 }])

    vi.advanceTimersByTime(34)
    expect(ephemeral().map((m) => m.payload.x)).toEqual([0, 9])
  })

  it("delivers remote broadcasts to on('broadcast')", () => {
    const { suite, fromParent } = boot()
    fromParent(snapshot(0))
    const got = []
    suite.on("broadcast", (ev) => got.push(ev))
    fromParent({ suite: 1, type: "ephemeral", channel: "cursor", payload: { x: 1 }, actor: "u-2" })
    expect(got).toEqual([{ channel: "cursor", payload: { x: 1 }, actor: "u-2" }])
  })
})

describe("suite.call (task 01a1316b-aab0 stage 2)", () => {
  it("posts a call and resolves with {ok, result} once the mirror reaches its seq", async () => {
    const { suite, fromParent, sent } = boot()
    fromParent(snapshot(0))

    let resolved = null
    suite.call("vote", { option: "a" }).then((r) => (resolved = r))
    const m = sent().at(-1)
    expect(m).toMatchObject({ type: "call", name: "vote", args: { option: "a" }, suite: 1 })

    fromParent({ suite: 1, type: "call_result", req: m.req, ok: true, seq: 1, result: { seq: 1, applied: 1 } })
    await Promise.resolve()
    expect(resolved).toBe(null)

    fromParent(keyDiff(1, "votes.a", 1, "u-1"))
    await Promise.resolve()
    expect(resolved).toEqual({ ok: true, result: { seq: 1, applied: 1 } })
  })

  it("rejects with an error carrying kind and code", async () => {
    const { suite, fromParent, sent } = boot()
    fromParent(snapshot(0))
    const p = suite.call("mk", {})
    const m = sent().at(-1)
    fromParent({
      suite: 1,
      type: "call_result",
      req: m.req,
      ok: false,
      kind: "forbidden",
      code: "binding_not_registered",
      message: "nope",
    })
    const err = await p.catch((e) => e)
    expect(err.kind).toBe("forbidden")
    expect(err.code).toBe("binding_not_registered")
    expect(err.message).toBe("binding_not_registered")
  })

  it("rejects not_connected before a snapshot and too_large over 16 KB of args", async () => {
    const { suite, fromParent, sent } = boot()
    await expect(suite.call("vote", {})).rejects.toMatchObject({ kind: "not_connected" })
    fromParent(snapshot(0))
    const before = sent().length
    await expect(suite.call("vote", { s: "x".repeat(16 * 1024) })).rejects.toMatchObject({ kind: "too_large" })
    expect(sent().length).toBe(before)
  })
})
