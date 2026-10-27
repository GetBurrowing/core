import { describe, it, expect } from "vitest"
import { readFileSync, readdirSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"
import {
  DIR_BROWSER_TO_CLI,
  DIR_CLI_TO_BROWSER,
  KIND_CONTROL,
  KIND_DATA,
  Receiver,
  Sender,
  deriveSessionKeys,
  fromB64,
  generateKeyPair,
  toB64,
} from "../../js/terminal/crypto.js"
import { TerminalSession } from "../../js/terminal/session.js"

const JS = resolve(dirname(fileURLToPath(import.meta.url)), "../../js")
const tick = () => new Promise((r) => setTimeout(r, 0))
const until = async (fn) => {
  for (let i = 0; i < 200; i++) {
    if (fn()) return
    await tick()
  }
  throw new Error("timed out waiting")
}

/** A terminal handle that records every call. It has only what the session may use. */
function fakeTerm() {
  const calls = []
  const written = []
  const term = {
    write: (b) => (calls.push("write"), written.push(Buffer.from(b).toString())),
    setInputEnabled: (on) => calls.push(`input:${on}`),
    setDimmed: (d) => calls.push(`dim:${d}`),
  }
  return new Proxy(term, {
    get(t, k) {
      if (k === "calls") return calls
      if (k === "written") return written
      if (!(k in t)) calls.push(`UNEXPECTED:${String(k)}`)
      return t[k]
    },
  })
}

/** The agent-machine side of a channel, speaking the real wire format. */
class FakeCli {
  constructor() {
    this.handlers = {}
    this.pushed = []
    this.closeCb = () => {}
    this.sid = "sid-" + Math.random().toString(36).slice(2)
    this.inFrames = []
  }
  adapter(joinResult) {
    return {
      on: (e, cb) => (this.handlers[e] = cb),
      onClose: (cb) => (this.closeCb = cb),
      join: () => (joinResult.error ? Promise.reject(joinResult.error) : Promise.resolve({ mode: "ro", session_id: this.sid })),
      push: (event, payload) => {
        this.pushed.push([event, payload])
        if (event === "hello") this.onBrowserHello(payload)
        if (event === "in") this.inFrames.push(payload)
        return Promise.resolve({ mode: payload?.mode })
      },
      leave: () => this.pushed.push(["__leave"]),
    }
  }
  async start() {
    this.kp = await generateKeyPair()
    this.handlers.hello({ pub: toB64(this.kp.publicRaw) })
  }
  async onBrowserHello(payload) {
    const keys = await deriveSessionKeys(this.kp.privateKey, fromB64(payload.pub), this.sid)
    // from the CLI's point of view: it sends with the cli->browser key, which
    // the browser opens as `recv`; the session derives these the same way round.
    this.out = new Sender(keys.recv, DIR_CLI_TO_BROWSER)
    this.inRecv = new Receiver(keys.send, DIR_BROWSER_TO_CLI)
    this.ready = true
  }
  async out_(kind, text) {
    const frame = await this.out.seal(kind, new TextEncoder().encode(text))
    this.handlers.out(frame)
  }
}

function makeSession(clis, opts = {}) {
  const term = fakeTerm()
  const states = []
  const modes = []
  const cwds = []
  const timers = []
  let n = 0
  const session = new TerminalSession({
    getToken: async () => "tok-" + ++n,
    connect: () => {
      const cli = clis[Math.min(clis.length - 1, session_connects.count++)]
      return cli.adapter(cli.joinResult ?? {})
    },
    term,
    onState: (s, r) => states.push(r ? `${s}:${r}` : s),
    onCwd: (c) => cwds.push(c),
    onMode: (m) => modes.push(m),
    schedule: (fn, ms) => {
      timers.push({ fn, ms })
      return () => {}
    },
    ...opts,
  })
  const session_connects = { count: 0 }
  return { session, term, states, modes, cwds, timers }
}

describe("handshake, output and mode", () => {
  it("connects, shows the starting folder, writes output, and keeps input off while read-only", async () => {
    const cli = new FakeCli()
    const { session, term, states, cwds } = makeSession([cli])
    await session.start()
    await cli.start()
    await until(() => states.includes("connected"))
    await until(() => cli.ready)

    await cli.out_(KIND_CONTROL, JSON.stringify({ cwd: "/work/example" }))
    await cli.out_(KIND_DATA, "hello \x1b[1mworld\x1b[0m")
    await until(() => term.written.length === 1)
    expect(cwds).toEqual(["/work/example"])
    expect(term.written[0]).toBe("hello \x1b[1mworld\x1b[0m")
    expect(states).toEqual(["connecting", "connected"])

    // read-only: nothing leaves the browser
    expect(await session.send(new TextEncoder().encode("abc\r"))).toBe(false)
    expect(cli.pushed.filter(([e]) => e === "in")).toHaveLength(0)
  })

  it("sends encrypted input only after core confirms Can type, and stops again on View only", async () => {
    const cli = new FakeCli()
    const { session, term, modes } = makeSession([cli])
    await session.start()
    await cli.start()
    await until(() => cli.ready)

    expect(await session.setMode("rw")).toBe(true)
    expect(session.mode).toBe("rw")
    expect(modes).toEqual(["rw"])
    expect(term.calls).toContain("input:true")

    await session.send(new TextEncoder().encode("xyz\r"))
    await until(() => cli.inFrames.length === 1)
    const opened = await cli.inRecv.open(cli.inFrames[0])
    expect(opened.kind).toBe(KIND_DATA)
    expect(Buffer.from(opened.body).toString()).toBe("xyz\r")
    // the frame on the wire is not the plaintext
    expect(Buffer.from(cli.inFrames[0]).includes(Buffer.from("xyz"))).toBe(false)

    await session.setMode("ro")
    expect(await session.send(new TextEncoder().encode("qqq\r"))).toBe(false)
    expect(cli.inFrames).toHaveLength(1)
  })

  it("keeps in-order counters for a burst of input", async () => {
    const cli = new FakeCli()
    const { session } = makeSession([cli])
    await session.start()
    await cli.start()
    await until(() => cli.ready)
    await session.setMode("rw")
    for (const ch of "abcdefgh") session.send(new TextEncoder().encode(ch))
    await until(() => cli.inFrames.length === 8)
    let text = ""
    for (const f of cli.inFrames) text += Buffer.from((await cli.inRecv.open(f)).body).toString()
    expect(text).toBe("abcdefgh")
  })
})

describe("refusals", () => {
  it.each(["forbidden", "flag_off"])("%s is final: it is shown and not retried", async (reason) => {
    const cli = new FakeCli()
    cli.joinResult = { error: { reason } }
    const { session, states, timers } = makeSession([cli])
    await session.start()
    expect(states).toEqual(["connecting", `refused:${reason}`])
    expect(timers).toHaveLength(0)
  })

  it("offline retries with backoff", async () => {
    const cli = new FakeCli()
    cli.joinResult = { error: { reason: "offline" } }
    const { session, states, timers } = makeSession([cli])
    await session.start()
    expect(states).toContain("offline:offline")
    expect(timers.map((t) => t.ms)).toEqual([1000])
    timers[0].fn()
    await until(() => timers.length === 2)
    expect(timers.map((t) => t.ms)).toEqual([1000, 2000])
  })
})

describe("a drop keeps the old output and never clears it", () => {
  it("dims, reconnects with a fresh token and handshake, and calls no clear or reset", async () => {
    const first = new FakeCli()
    const second = new FakeCli()
    const { session, term, states, modes, timers } = makeSession([first, second])
    await session.start()
    await first.start()
    await until(() => first.ready)
    await session.setMode("rw")
    await first.out_(KIND_DATA, "old output")
    await until(() => term.written.length === 1)

    first.closeCb() // the socket drops
    expect(states.at(-1)).toBe("reconnecting")
    expect(term.calls).toContain("dim:true")
    expect(term.calls).toContain("input:false")
    expect(session.mode).toBe("ro") // every new session starts read-only
    expect(modes.at(-1)).toBe("ro")
    expect(await session.send(new TextEncoder().encode("x"))).toBe(false)

    timers.at(-1).fn()
    await until(() => second.handlers.hello)
    await second.start()
    await until(() => second.ready)
    await second.out_(KIND_DATA, "redrawn from tmux")
    await until(() => term.written.length === 2)

    expect(term.written).toEqual(["old output", "redrawn from tmux"])
    expect(term.calls.at(-1)).not.toBe("dim:true")
    expect(states.at(-1)).toBe("connected")
    // The handle has no clear or reset, and nothing else was reached for.
    expect(term.calls.filter((c) => /clear|reset|UNEXPECTED/i.test(c))).toEqual([])
  })

  it("detach leaves the channel and stops retrying", async () => {
    const cli = new FakeCli()
    const { session, timers } = makeSession([cli])
    await session.start()
    await cli.start()
    await until(() => cli.ready)
    session.detach()
    expect(cli.pushed.some(([e]) => e === "detach")).toBe(true)
    expect(cli.pushed.some(([e]) => e === "__leave")).toBe(true)
    cli.closeCb()
    expect(timers).toHaveLength(0)
  })
})

describe("source guards for the browser end", () => {
  const files = [
    ...readdirSync(resolve(JS, "terminal")).map((f) => resolve(JS, "terminal", f)),
    resolve(JS, "terminal_island.js"),
    resolve(JS, "hooks/terminal_host.js"),
    resolve(JS, "lib/load_terminal.js"),
  ]
  const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1")

  it("never clears or resets the terminal", () => {
    for (const f of files) {
      const code = strip(readFileSync(f, "utf8"))
      expect(code, f).not.toMatch(/\.(clear|reset)\s*\(/)
      expect(code, f).not.toMatch(/\\x1bc|\\x1b\[2J|\\u001bc/)
    }
  })

  it("stores and logs nothing", () => {
    for (const f of files) {
      const code = strip(readFileSync(f, "utf8"))
      expect(code, f).not.toMatch(/localStorage|sessionStorage|indexedDB|document\.cookie/)
      expect(code, f).not.toMatch(/console\.\w+/)
    }
  })

  it("never inspects output: the output path only decrypts and writes", () => {
    const code = strip(readFileSync(resolve(JS, "terminal/session.js"), "utf8"))
    const outPath = code.slice(code.indexOf("async #onOut"), code.indexOf("#dropped(chan) {"))
    expect(outPath).toContain("this.o.term.write(rec.body)")
    expect(outPath).not.toMatch(/\.(match|test|replace|includes|indexOf|search)\s*\(/)
  })
})
