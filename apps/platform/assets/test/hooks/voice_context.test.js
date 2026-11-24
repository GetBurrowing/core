import { describe, it, expect, beforeEach } from "vitest"
import VoiceContext, { NAMESPACE, KEY } from "../../js/hooks/voice_context.js"
import { __resetForTests } from "../../js/client_state.js"

/**
 * VoiceContext (task 01a1557a-eab7 stage 2; the partner since task 01a20dc5):
 * the Voice tab's last context and, per user, its last partner are remembered
 * on the device and pushed back on mount AND on reconnect, for the keys the
 * server renders in data-keys. The server's `voice_saved` is the only writer.
 */
function stubStorage() {
  const store = new Map()
  globalThis.localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
    key: (i) => Array.from(store.keys())[i] ?? null,
    get length() {
      return store.size
    },
  }
  return store
}

const PARTNER = "burrow-voice-partner:u1"
const KEYS = `${KEY} ${PARTNER}`

function mountHook(dataset = { keys: KEYS }) {
  const pushed = []
  const handlers = {}
  const hook = Object.create(VoiceContext)
  hook.el = { dataset }
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  hook.handleEvent = (event, fn) => (handlers[event] = fn)
  hook.mounted()
  return { hook, pushed, handlers }
}

const remember = (store, key, id) => store.set(`suite:${NAMESPACE}:${key}`, JSON.stringify(id))

describe("VoiceContext", () => {
  let store

  beforeEach(() => {
    store = stubStorage()
    __resetForTests()
  })

  it("pushes nothing on a device that remembers nothing", () => {
    const { pushed } = mountHook()
    expect(pushed).toEqual([])
  })

  it("pushes the remembered context and partner once on mount", () => {
    remember(store, KEY, "space-1")
    remember(store, PARTNER, "agent-7")
    const { pushed } = mountHook()
    expect(pushed).toEqual([["voice_restore", { [KEY]: "space-1", [PARTNER]: "agent-7" }]])
  })

  it("reads only the keys the server lists (another user's partner stays put)", () => {
    remember(store, "burrow-voice-partner:someone-else", "agent-9")
    const { pushed } = mountHook()
    expect(pushed).toEqual([])
  })

  // The bug Ryan hit on the device: a reconnect mounts a fresh VoiceLive on
  // Burrow, and LiveView calls reconnected(), not mounted(), on the hook.
  it("pushes them again on reconnect, so the server puts the partner back", () => {
    const { hook, pushed, handlers } = mountHook()
    handlers.voice_saved({ key: PARTNER, id: "agent-7" })
    expect(pushed).toEqual([])
    hook.reconnected()
    expect(pushed).toEqual([["voice_restore", { [PARTNER]: "agent-7" }]])
  })

  it("stores the server's pick and clears on null", () => {
    const { handlers } = mountHook()
    handlers.voice_saved({ key: KEY, id: "space-2" })
    expect(JSON.parse(store.get(`suite:voice:${KEY}`))).toBe("space-2")
    handlers.voice_saved({ key: KEY, id: null })
    expect(store.has(`suite:voice:${KEY}`)).toBe(false)
    handlers.voice_saved({ key: PARTNER, id: "agent-3" })
    expect(JSON.parse(store.get(`suite:voice:${PARTNER}`))).toBe("agent-3")
  })
})
