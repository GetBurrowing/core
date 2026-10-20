import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { ClientState, __resetForTests } from "../js/client_state.js"

/**
 * Tests for `Suite.ClientState` — the single localStorage-wrapping API
 * (task 019f3e9a stage 1).
 *
 * Vitest runs in the default `node` env, so there is no global
 * `localStorage`. We install a minimal in-memory fake on `globalThis`
 * before each test and tear it down afterwards. Two special-purpose
 * fakes cover the failure modes:
 *   - a quota-exceeded stub whose `setItem` throws `QuotaExceededError`
 *   - a private-mode stub that throws a `SecurityError` from the
 *     `localStorage` getter itself (Safari's contract)
 *
 * The module holds internal `disabled` and `memory` state at module
 * scope; `__resetForTests()` clears both between tests so each case
 * starts from a clean slate.
 */

function makeFakeStorage() {
  const store = new Map()
  return {
    get length() {
      return store.size
    },
    key(index) {
      return Array.from(store.keys())[index] ?? null
    },
    getItem(key) {
      return store.has(key) ? store.get(key) : null
    },
    setItem(key, value) {
      store.set(key, String(value))
    },
    removeItem(key) {
      store.delete(key)
    },
    clear() {
      store.clear()
    },
    // Convenience for assertions — not part of the spec surface.
    __raw: store,
  }
}

function installFakeStorage() {
  const fake = makeFakeStorage()
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    get() {
      return fake
    },
  })
  return fake
}

function uninstallStorage() {
  try {
    delete globalThis.localStorage
  } catch (_err) {
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      value: undefined,
    })
  }
}

describe("ClientState", () => {
  let storage

  beforeEach(() => {
    storage = installFakeStorage()
    __resetForTests()
  })

  afterEach(() => {
    uninstallStorage()
    __resetForTests()
  })

  describe("roundtrip", () => {
    it("stores and retrieves a string", () => {
      ClientState.set("ns", "greeting", "hello")
      expect(ClientState.get("ns", "greeting")).toBe("hello")
    })

    it("stores and retrieves a number", () => {
      ClientState.set("sidebar", "width", 320)
      expect(ClientState.get("sidebar", "width")).toBe(320)
    })

    it("stores and retrieves an object", () => {
      const obj = { a: 1, b: [2, 3], c: { d: "x" } }
      ClientState.set("prefs", "layout", obj)
      expect(ClientState.get("prefs", "layout")).toEqual(obj)
    })

    it("stores under the suite:<namespace>:<key> prefix", () => {
      ClientState.set("route_resume", "chat", "/chat/abc")
      expect(storage.__raw.has("suite:route_resume:chat")).toBe(true)
    })

    it("get parses legacy raw-string values (byte-identical migration)", () => {
      // Simulate a legacy caller: `localStorage.setItem(k, "blocked")`.
      storage.__raw.set("suite:tasks_ui:status_filter", "blocked")
      expect(ClientState.get("tasks_ui", "status_filter")).toBe("blocked")
    })
  })

  describe("defaults", () => {
    it("returns defaultValue when the key is missing", () => {
      expect(ClientState.get("ns", "missing", "fallback")).toBe("fallback")
    })

    it("returns null by default when the key is missing", () => {
      expect(ClientState.get("ns", "missing")).toBeNull()
    })
  })

  describe("clear(namespace)", () => {
    it("removes only that namespace's keys, leaving siblings untouched", () => {
      ClientState.set("a", "one", 1)
      ClientState.set("a", "two", 2)
      ClientState.set("b", "one", 10)

      ClientState.clear("a")

      expect(ClientState.get("a", "one")).toBeNull()
      expect(ClientState.get("a", "two")).toBeNull()
      expect(ClientState.get("b", "one")).toBe(10)
    })
  })

  describe("clearAll()", () => {
    it("wipes everything under the suite: prefix", () => {
      ClientState.set("a", "one", 1)
      ClientState.set("b", "two", 2)
      // Unrelated non-suite key MUST survive.
      storage.__raw.set("burrow-theme-v1", "{\"preset\":\"burrow\",\"mode\":\"dark\"}")

      ClientState.clearAll()

      expect(ClientState.get("a", "one")).toBeNull()
      expect(ClientState.get("b", "two")).toBeNull()
      expect(storage.__raw.get("burrow-theme-v1")).toBe("{\"preset\":\"burrow\",\"mode\":\"dark\"}")
    })
  })

  describe("quota-exceeded fallback", () => {
    it("survives QuotaExceededError and round-trips via in-memory Map", () => {
      const err = new Error("quota")
      err.name = "QuotaExceededError"
      storage.setItem = () => {
        throw err
      }

      expect(() => ClientState.set("ns", "key", "value")).not.toThrow()
      expect(ClientState.get("ns", "key")).toBe("value")
      expect(ClientState.available()).toBe(false)
    })
  })

  describe("private-mode fallback (SecurityError)", () => {
    it("survives when the localStorage getter itself throws SecurityError", () => {
      // Rebind globalThis.localStorage so any access throws — mimics
      // Safari private mode where the property access itself fails.
      Object.defineProperty(globalThis, "localStorage", {
        configurable: true,
        get() {
          const err = new Error("private mode")
          err.name = "SecurityError"
          throw err
        },
      })
      __resetForTests()

      expect(() => ClientState.set("ns", "key", "value")).not.toThrow()
      expect(() => ClientState.get("ns", "key")).not.toThrow()
      expect(ClientState.get("ns", "key")).toBe("value")
      expect(ClientState.available()).toBe(false)

      expect(() => ClientState.remove("ns", "key")).not.toThrow()
      expect(ClientState.get("ns", "key")).toBeNull()

      ClientState.set("ns", "k1", 1)
      ClientState.set("ns", "k2", 2)
      expect(() => ClientState.clear("ns")).not.toThrow()
      expect(ClientState.get("ns", "k1")).toBeNull()

      expect(() => ClientState.clearAll()).not.toThrow()
    })
  })

  describe("TTL envelope", () => {
    it("treats an already-expired ttlMs as missing and returns default", () => {
      ClientState.set("ns", "ephemeral", "gone", { ttlMs: -1 })
      expect(ClientState.get("ns", "ephemeral", "default")).toBe("default")
    })

    it("returns the value while ttl has not elapsed", () => {
      ClientState.set("ns", "live", "here", { ttlMs: 60_000 })
      expect(ClientState.get("ns", "live")).toBe("here")
    })

    it("proactively removes the underlying entry when expired", () => {
      ClientState.set("ns", "ephemeral", "gone", { ttlMs: -1 })
      // First read triggers cleanup.
      ClientState.get("ns", "ephemeral")
      expect(storage.__raw.has("suite:ns:ephemeral")).toBe(false)
    })

    it("passes non-envelope plain JSON values through unchanged", () => {
      // Directly plant a non-envelope object; get must return it as-is.
      storage.__raw.set("suite:ns:plain", JSON.stringify({ hello: "world" }))
      expect(ClientState.get("ns", "plain")).toEqual({ hello: "world" })
    })
  })

  describe("available()", () => {
    it("reports true in the healthy path", () => {
      ClientState.set("ns", "key", 1)
      expect(ClientState.available()).toBe(true)
    })
  })
})
