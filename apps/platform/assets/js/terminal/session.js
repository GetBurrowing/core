// The browser end of one remote terminal, as a state machine with every
// outside thing injected (socket, terminal, crypto, timers) so it is testable
// in node with no DOM.
//
// Rules this file keeps:
//   * Output is written to the terminal as it arrives and is NEVER inspected.
//     The only record this reads is the first encrypted control record
//     (`{"cwd": ...}`), which is not terminal output.
//   * The terminal handle it is given has no clear or reset on it. A drop only
//     dims what is on screen; a new handshake draws over it from tmux.
//   * Input is dropped here while read-only, in addition to core dropping it.
//   * No plaintext fallback: without keys nothing is sent.
//   * Nothing is logged and nothing is stored.

import * as realCrypto from "./crypto.js"

/**
 * Phoenix's client sends a binary push only for an ArrayBuffer; a Uint8Array
 * would be JSON-encoded as an object. Hand it an exact-size ArrayBuffer.
 */
export function toArrayBuffer(bytes) {
  if (!(bytes instanceof Uint8Array)) return bytes
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
}

// A push whose reply nobody awaits must not become an unhandled rejection.
const fire = (p) => p?.catch?.(() => {})

const MAX_BACKOFF_MS = 15000
const FIRST_BACKOFF_MS = 1000

export class TerminalSession {
  #chan = null
  #stopped = false
  #attempt = 0
  #mode = "ro"
  #sender = null
  #receiver = null
  #sendChain = Promise.resolve()
  #inChain = Promise.resolve()
  #cancelRetry = null
  #everConnected = false
  #size = { cols: 80, rows: 24 }

  /**
   * @param {object} o
   * @param {() => Promise<string>} o.getToken   a fresh 60s socket token
   * @param {(token: string) => object} o.connect  channel adapter, see below
   * @param {object} o.term   { write(bytes), setInputEnabled(bool), setDimmed(bool) }
   * @param {(state: string, reason?: string) => void} o.onState
   * @param {(cwd: string) => void} o.onCwd
   * @param {(mode: string) => void} o.onMode
   * @param {object} [o.crypto]
   * @param {(fn: () => void, ms: number) => () => void} [o.schedule]
   *
   * Channel adapter: `join(): Promise<{session_id}>` (rejects `{reason}`),
   * `on(event, cb)` registered before `join`, `push(event, payload): Promise`,
   * `onClose(cb)`, `leave()`.
   */
  constructor(o) {
    this.o = o
    this.crypto = o.crypto ?? realCrypto
    this.schedule =
      o.schedule ??
      ((fn, ms) => {
        const t = setTimeout(fn, ms)
        return () => clearTimeout(t)
      })
  }

  get mode() {
    return this.#mode
  }

  start() {
    this.#stopped = false
    return this.#connectOnce()
  }

  async #connectOnce() {
    if (this.#stopped) return
    const { o } = this
    o.onState(this.#everConnected ? "reconnecting" : "connecting")

    let chan
    try {
      const token = await o.getToken()
      if (this.#stopped) return
      if (!token) return this.#retry()
      chan = o.connect(token)
    } catch {
      return this.#retry()
    }
    this.#chan = chan

    const keyPair = await this.crypto.generateKeyPair()
    let joinedResolve
    const joined = new Promise((r) => (joinedResolve = r))
    let sessionId = null

    chan.on("hello", (payload) => {
      this.#inChain = this.#inChain.then(async () => {
        await joined
        if (this.#chan !== chan || sessionId === null) return
        await this.#onHello(chan, keyPair, sessionId, payload)
      })
    })
    chan.on("out", (frame) => {
      // Phoenix hands a binary push over as an ArrayBuffer.
      const bytes = frame instanceof Uint8Array ? frame : new Uint8Array(frame)
      this.#inChain = this.#inChain.then(() => this.#onOut(chan, bytes))
    })
    chan.on("closed", () => this.#dropped(chan))
    chan.onClose(() => this.#dropped(chan))

    let resp
    try {
      resp = await chan.join()
    } catch (err) {
      this.#chan = null
      joinedResolve()
      return this.#refused(err)
    }
    sessionId = resp?.session_id ?? null
    joinedResolve()
    if (sessionId === null) {
      this.#chan = null
      return this.#retry()
    }
  }

  #refused(err) {
    const reason = err?.reason ?? "error"
    if (reason === "forbidden" || reason === "flag_off") {
      // A setting or a boundary, not a failure to retry through.
      this.o.onState("refused", reason)
      return
    }
    if (reason === "offline") this.o.onState("offline", reason)
    return this.#retry()
  }

  async #onHello(chan, keyPair, sessionId, payload) {
    if (this.#sender) return
    let peer
    try {
      peer = this.crypto.fromB64(String(payload?.pub ?? ""))
      if (peer.length !== 32) return
      const keys = await this.crypto.deriveSessionKeys(keyPair.privateKey, peer, sessionId)
      this.#sender = new this.crypto.Sender(keys.send, this.crypto.DIR_BROWSER_TO_CLI)
      this.#receiver = new this.crypto.Receiver(keys.recv, this.crypto.DIR_CLI_TO_BROWSER)
    } catch {
      return
    }
    fire(chan.push("hello", { pub: this.crypto.toB64(keyPair.publicRaw) }))
    fire(chan.push("resize", { cols: this.#size.cols, rows: this.#size.rows }))
    this.#attempt = 0
    this.#everConnected = true
    this.o.term.setDimmed(false)
    this.o.onState("connected")
  }

  async #onOut(chan, frame) {
    if (this.#chan !== chan || !this.#receiver) return
    const rec = await this.#receiver.open(frame)
    if (rec === null) return
    if (rec.kind === this.crypto.KIND_CONTROL) {
      try {
        const cwd = JSON.parse(new TextDecoder().decode(rec.body)).cwd
        if (typeof cwd === "string") this.o.onCwd(cwd)
      } catch {
        /* a control record we do not understand is ignored */
      }
      return
    }
    if (rec.kind === this.crypto.KIND_DATA) this.o.term.write(rec.body)
  }

  #dropped(chan) {
    if (this.#stopped || this.#chan !== chan) return
    this.#chan = null
    this.#sender = null
    this.#receiver = null
    // Core starts every session read-only; say so rather than imply otherwise.
    this.#mode = "ro"
    this.o.term.setInputEnabled(false)
    this.o.term.setDimmed(true)
    this.o.onMode("ro")
    this.o.onState("reconnecting")
    this.#retry()
  }

  #retry() {
    if (this.#stopped) return
    const delay = Math.min(FIRST_BACKOFF_MS * 2 ** this.#attempt, MAX_BACKOFF_MS)
    this.#attempt += 1
    this.#cancelRetry = this.schedule(() => {
      this.#cancelRetry = null
      this.#connectOnce()
    }, delay)
  }

  /** The terminal's size changed. */
  resize(cols, rows) {
    this.#size = { cols, rows }
    if (this.#sender && this.#chan) fire(this.#chan.push("resize", { cols, rows }))
  }

  /** Ask core for `mode`. The page shows it only once core confirms. */
  async setMode(mode) {
    if ((mode !== "ro" && mode !== "rw") || !this.#chan || !this.#sender) return false
    const chan = this.#chan
    try {
      await chan.push("mode", { mode })
    } catch {
      return false
    }
    if (this.#chan !== chan) return false
    this.#mode = mode
    this.o.term.setInputEnabled(mode === "rw")
    this.o.onMode(mode)
    return true
  }

  /** Keys typed or pasted by the user. Dropped unless the mode is rw and keys exist. */
  send(bytes) {
    if (this.#mode !== "rw" || !this.#sender || !this.#chan) return Promise.resolve(false)
    const chan = this.#chan
    const sender = this.#sender
    this.#sendChain = this.#sendChain.then(async () => {
      if (this.#chan !== chan || this.#mode !== "rw") return false
      const frame = await sender.seal(this.crypto.KIND_DATA, bytes)
      fire(chan.push("in", frame))
      return true
    })
    return this.#sendChain
  }

  /** Leave: detaches only this client; the agent's session keeps running. */
  detach() {
    this.#stopped = true
    if (this.#cancelRetry) this.#cancelRetry()
    const chan = this.#chan
    this.#chan = null
    this.#sender = null
    this.#receiver = null
    if (chan) {
      try {
        fire(chan.push("detach", {}))
        chan.leave()
      } catch {
        /* already gone */
      }
    }
  }
}
