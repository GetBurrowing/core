import { describe, it, expect, beforeEach } from "vitest"
import VoiceContext, { NAMESPACE, KEY } from "../../js/hooks/voice_context.js"
import { __resetForTests } from "../../js/client_state.js"

/**
 * VoiceContext (task 01a1557a-eab7 stage 2): the Voice tab's last context is
 * remembered per device and pushed back ONCE on mount; the server's
 * `voice_ctx_saved` is the only writer.
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

function mountHook(dataset = {}) {
  const pushed = []
  const handlers = {}
  const hook = Object.create(VoiceContext)
  hook.el = { dataset }
  hook.pushEvent = (event, payload) => pushed.push([event, payload])
  hook.handleEvent = (event, fn) => (handlers[event] = fn)
  hook.mounted()
  return { pushed, handlers }
}

describe("VoiceContext", () => {
  let store

  beforeEach(() => {
    store = stubStorage()
    __resetForTests()
  })

  it("pushes nothing on a device that remembers no context", () => {
    const { pushed } = mountHook()
    expect(pushed).toEqual([])
  })

  it("pushes the remembered space id once on mount", () => {
    store.set(`suite:${NAMESPACE}:${KEY}`, JSON.stringify("space-1"))
    const { pushed } = mountHook()
    expect(pushed).toEqual([["voice_restore_context", { id: "space-1" }]])
  })

  it("does not push when the server already shows that context", () => {
    store.set(`suite:${NAMESPACE}:${KEY}`, JSON.stringify("space-1"))
    const { pushed } = mountHook({ contextId: "space-1" })
    expect(pushed).toEqual([])
  })

  it("stores the server's pick and clears on null", () => {
    const { handlers } = mountHook()
    handlers.voice_ctx_saved({ id: "space-2" })
    expect(JSON.parse(store.get("suite:voice:burrow-voice-ctx"))).toBe("space-2")
    handlers.voice_ctx_saved({ id: null })
    expect(store.has("suite:voice:burrow-voice-ctx")).toBe(false)
  })
})
