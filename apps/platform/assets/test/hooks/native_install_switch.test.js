import { describe, it, expect, vi, afterEach } from "vitest"
import NativeInstallSwitch, {
  installBadgesPlugin
} from "../../js/hooks/native_install_switch.js"
import { __resetWebSwitchForTests } from "../../js/hooks/install_switch_web.js"
import { fakeDoc, fakeStorage, switchButton } from "../lib/switcher_fake_dom.js"

/**
 * The `NativeInstallSwitch` hook (task 01a1261e stage 3): the install
 * switcher button in the shell's utility bar, and its unread dot.
 *
 * vitest runs in plain node here (no DOM), so the button, its dot, `window`
 * and `document` are small fakes that record class changes and listeners.
 */

function fakeClassList(initial) {
  const set = new Set(initial)
  return {
    add: c => set.add(c),
    remove: c => set.delete(c),
    contains: c => set.has(c),
    set
  }
}

function fakeTarget() {
  const listeners = {}
  return {
    listeners,
    addEventListener: (name, fn) => {
      ;(listeners[name] ||= []).push(fn)
    },
    removeEventListener: (name, fn) => {
      listeners[name] = (listeners[name] || []).filter(f => f !== fn)
    },
    fire(name) {
      for (const fn of listeners[name] || []) fn()
    }
  }
}

function fakeButton() {
  const dot = { classList: fakeClassList(["hidden", "size-2", "rounded-full", "bg-primary"]) }
  const el = Object.assign(fakeTarget(), {
    classList: fakeClassList(["hidden", "items-center"]),
    querySelector: sel => (sel === "[data-role='install-unread-dot']" ? dot : null)
  })
  return { el, dot }
}

function stubEnv({ native = true, plugin } = {}) {
  const win = Object.assign(fakeTarget(), {
    Capacitor: {
      isNativePlatform: () => native,
      Plugins: plugin ? { SuiteNative: plugin } : {}
    }
  })
  const doc = Object.assign(fakeTarget(), { visibilityState: "visible" })
  vi.stubGlobal("window", win)
  vi.stubGlobal("document", doc)
  return { win, doc }
}

function mount() {
  const { el, dot } = fakeButton()
  const hook = Object.assign(Object.create(NativeInstallSwitch), { el })
  hook.mounted()
  return { hook, el, dot }
}

const flush = () => new Promise(resolve => setTimeout(resolve, 0))
const visible = el => !el.classList.contains("hidden")

// The web path needs a real-ish DOM: swap the stubbed document for the
// switcher fake DOM, keeping the stubbed window's listeners.
function mountWeb(stubbedDoc) {
  const doc = Object.assign(fakeDoc(), { listeners: stubbedDoc.listeners })
  const win = globalThis.window
  Object.assign(win, {
    location: { origin: "https://a.example", host: "a.example", pathname: "/", search: "", assign: vi.fn() },
    localStorage: fakeStorage(),
    sessionStorage: fakeStorage(),
    fetch: vi.fn()
  })
  vi.stubGlobal("document", doc)
  const { button } = switchButton(doc)
  const hook = Object.assign(Object.create(NativeInstallSwitch), { el: button })
  hook.mounted()
  return { el: button, hook }
}

afterEach(() => {
  __resetWebSwitchForTests()
  vi.unstubAllGlobals()
})

describe("installBadgesPlugin", () => {
  it("is null in a plain browser", () => {
    expect(installBadgesPlugin({})).toBe(null)
  })

  it("is null when Capacitor reports the web platform", () => {
    const win = {
      Capacitor: { isNativePlatform: () => false, Plugins: { SuiteNative: { installBadges() {} } } }
    }
    expect(installBadgesPlugin(win)).toBe(null)
  })

  it("is null on a shipped app build whose plugin has no installBadges", () => {
    const win = {
      Capacitor: { isNativePlatform: () => true, Plugins: { SuiteNative: { switchInstall() {} } } }
    }
    expect(installBadgesPlugin(win)).toBe(null)
  })

  it("returns SuiteNative when installBadges is a function", () => {
    const plugin = { installBadges() {} }
    const win = { Capacitor: { isNativePlatform: () => true, Plugins: { SuiteNative: plugin } } }
    expect(installBadgesPlugin(win)).toBe(plugin)
  })

  // Task 01a14ba9 stage 4: BurrowNative (newer builds) or SuiteNative (older).
  it("Burrow-only: returns BurrowNative", () => {
    const plugin = { installBadges() {} }
    const win = { Capacitor: { isNativePlatform: () => true, Plugins: { BurrowNative: plugin } } }
    expect(installBadgesPlugin(win)).toBe(plugin)
  })

  it("both present: BurrowNative wins", () => {
    const burrow = { installBadges() {} }
    const suite = { installBadges() {} }
    const win = {
      Capacitor: { isNativePlatform: () => true, Plugins: { BurrowNative: burrow, SuiteNative: suite } }
    }
    expect(installBadgesPlugin(win)).toBe(burrow)
  })
})

describe("visibility of the button", () => {
  // Task 01a1ccd4 stage 3 changed this on purpose: in a browser the button
  // now reveals and runs the WEB switcher (install_switch_web.test.js). What
  // stays true is that the native bridge is never touched there.
  it("in a browser the native bridge is never called and no native listener is attached", async () => {
    const installBadges = vi.fn()
    const { win, doc } = stubEnv({ native: false, plugin: { installBadges } })
    const switchInstall = vi.fn()
    win.Capacitor.Plugins.SuiteNative.switchInstall = switchInstall
    const { el } = mountWeb(doc)
    el.click()
    await flush()

    expect(installBadges).not.toHaveBeenCalled()
    expect(switchInstall).not.toHaveBeenCalled()
    expect(win.listeners.burrowInstallBadges || []).toEqual([])
  })

  it("stays hidden on a native build without installBadges", async () => {
    const switchInstall = vi.fn()
    stubEnv({ plugin: { switchInstall } })
    const { el } = mount()
    el.fire("click")
    await flush()

    expect(visible(el)).toBe(false)
    expect(switchInstall).not.toHaveBeenCalled()
  })

  it("reveals as a flex row on a native build with installBadges", async () => {
    stubEnv({ plugin: { installBadges: async () => ({ others_unread: false }) } })
    const { el } = mount()
    await flush()

    expect(visible(el)).toBe(true)
    expect(el.classList.contains("flex")).toBe(true)
  })

  it("re-reveals after a LiveView patch restores the server's hidden class", async () => {
    stubEnv({ plugin: { installBadges: async () => ({ others_unread: true }) } })
    const { hook, el, dot } = mount()
    await flush()

    // What a shell re-render does to the element and its children.
    el.classList.add("hidden")
    el.classList.remove("flex")
    dot.classList.add("hidden")
    hook.updated()

    expect(visible(el)).toBe(true)
    expect(visible(dot)).toBe(true)
  })
})

describe("the unread dot", () => {
  it("shows for others_unread: true and stays hidden for false", async () => {
    stubEnv({ plugin: { installBadges: async () => ({ others_unread: true }) } })
    const on = mount()
    await flush()
    expect(visible(on.dot)).toBe(true)

    stubEnv({ plugin: { installBadges: async () => ({ others_unread: false }) } })
    const off = mount()
    await flush()
    expect(visible(off.dot)).toBe(false)
  })

  it("hides again after burrowInstallBadges when the answer flips", async () => {
    let answer = true
    const installBadges = vi.fn(async () => ({ others_unread: answer }))
    const { win } = stubEnv({ plugin: { installBadges } })
    const { dot } = mount()
    await flush()
    expect(visible(dot)).toBe(true)

    answer = false
    win.fire("burrowInstallBadges")
    await flush()

    expect(installBadges).toHaveBeenCalledTimes(2)
    expect(visible(dot)).toBe(false)
  })

  it("re-queries when the page becomes visible, not when it is hidden", async () => {
    const installBadges = vi.fn(async () => ({ others_unread: false }))
    const { doc } = stubEnv({ plugin: { installBadges } })
    mount()
    await flush()

    doc.visibilityState = "hidden"
    doc.fire("visibilitychange")
    await flush()
    expect(installBadges).toHaveBeenCalledTimes(1)

    doc.visibilityState = "visible"
    doc.fire("visibilitychange")
    await flush()
    expect(installBadges).toHaveBeenCalledTimes(2)
  })

  it("a rejected installBadges leaves the dot hidden, even after it was on", async () => {
    let fail = false
    const installBadges = vi.fn(async () => {
      if (fail) throw new Error("bridge gone")
      return { others_unread: true }
    })
    const { win } = stubEnv({ plugin: { installBadges } })
    const { dot } = mount()
    await flush()
    expect(visible(dot)).toBe(true)

    fail = true
    win.fire("burrowInstallBadges")
    await flush()
    expect(visible(dot)).toBe(false)
  })

  it("a rejection on mount leaves the dot hidden and raises nothing", async () => {
    stubEnv({ plugin: { installBadges: () => Promise.reject(new Error("no")) } })
    const { el, dot } = mount()
    await flush()

    expect(visible(el)).toBe(true)
    expect(visible(dot)).toBe(false)
  })

  it("a malformed answer or a synchronous throw hides the dot", async () => {
    stubEnv({ plugin: { installBadges: async () => ({ others_unread: "yes" }) } })
    const malformed = mount()
    await flush()
    expect(visible(malformed.dot)).toBe(false)

    stubEnv({
      plugin: {
        installBadges: () => {
          throw new Error("sync")
        }
      }
    })
    const thrown = mount()
    await flush()
    expect(visible(thrown.dot)).toBe(false)
  })

  it("an older answer arriving after a newer one does not win", async () => {
    const resolvers = []
    const installBadges = () => new Promise(resolve => resolvers.push(resolve))
    const { win } = stubEnv({ plugin: { installBadges } })
    const { dot } = mount()

    win.fire("burrowInstallBadges")
    resolvers[1]({ others_unread: false })
    await flush()
    resolvers[0]({ others_unread: true })
    await flush()

    expect(visible(dot)).toBe(false)
  })
})

describe("click", () => {
  it("calls switchInstall exactly once per tap", async () => {
    const switchInstall = vi.fn(async () => {})
    stubEnv({ plugin: { installBadges: async () => ({ others_unread: false }), switchInstall } })
    const { el } = mount()
    el.fire("click")
    await flush()

    expect(switchInstall).toHaveBeenCalledTimes(1)
  })

  it("a rejected switchInstall is swallowed", async () => {
    const switchInstall = vi.fn(() => Promise.reject(new Error("cancelled")))
    stubEnv({ plugin: { installBadges: async () => ({ others_unread: false }), switchInstall } })
    const { el } = mount()
    el.fire("click")
    await flush()

    expect(switchInstall).toHaveBeenCalledTimes(1)
  })
})

describe("destroyed", () => {
  it("removes every listener it added", async () => {
    const { win, doc } = stubEnv({ plugin: { installBadges: async () => ({ others_unread: false }) } })
    const { hook, el } = mount()
    await flush()
    hook.destroyed()

    expect(win.listeners.burrowInstallBadges).toEqual([])
    expect(doc.listeners.visibilitychange).toEqual([])
    expect(el.listeners.click).toEqual([])
  })
})
