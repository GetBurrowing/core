import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingSpeakerButton from "../../js/hooks/meeting_speaker_button.js"

// WKWebView cannot route audio (no setSinkId), so the Speaker button drives
// the native call's speakerphone through `SuiteMeetings.setSpeaker` and
// draws only what the native call reports.

function fakeButton() {
  const attrs = {}
  const listeners = {}
  return {
    hidden: true,
    dataset: {},
    attrs,
    setAttribute(name, value) {
      attrs[name] = String(value)
    },
    removeAttribute(name) {
      delete attrs[name]
    },
    addEventListener(event, cb) {
      listeners[event] = cb
    },
    removeEventListener(event) {
      delete listeners[event]
    },
    click() {
      listeners.click && listeners.click({ preventDefault() {} })
    },
  }
}

// A native call whose output follows the preference unless a headset is in.
function speakerPlugin({ speakerCap = true, headset = false, initial = true } = {}) {
  const plugin = {
    listeners: {},
    requests: [],
    output: initial && !headset,
    capabilities: () => Promise.resolve({ mic: true, camera: true, activeSpeakers: true, speaker: speakerCap }),
    state: () => Promise.resolve({ mic: true, camera: false, speaker: plugin.output }),
    setSpeaker({ on }) {
      plugin.requests.push(on)
      plugin.output = on && !headset
      return Promise.resolve({ speaker: on })
    },
    addListener(event, cb) {
      plugin.listeners[event] = cb
      return Promise.resolve({ remove() {} })
    },
  }
  return plugin
}

function mount() {
  const hook = Object.create(MeetingSpeakerButton)
  hook.el = fakeButton()
  hook.mounted()
  return hook
}

const flush = () => new Promise((resolve) => setImmediate(resolve))

describe("MeetingSpeakerButton", () => {
  let priorWindow

  beforeEach(() => {
    priorWindow = globalThis.window
    globalThis.window = {}
  })

  afterEach(() => {
    globalThis.window = priorWindow
  })

  it("stays hidden in a browser (no plugin)", async () => {
    const hook = mount()
    await hook._ready
    expect(hook.el.hidden).toBe(true)
  })

  it("stays hidden on a build that does not report the speaker capability", async () => {
    const plugin = speakerPlugin({ speakerCap: false })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = mount()
    await hook._ready
    expect(hook.el.hidden).toBe(true)
  })

  it("shows on a speaker-capable build with the native call's current output", async () => {
    window.Capacitor = { Plugins: { SuiteMeetings: speakerPlugin({ initial: true }) } }
    const hook = mount()
    await hook._ready
    expect(hook.el.hidden).toBe(false)
    expect(hook.el.attrs["aria-pressed"]).toBe("true")
    expect(hook.el.dataset.on).toBe("true")
  })

  it("a tap asks the native call for the speaker and draws the confirmed output", async () => {
    const plugin = speakerPlugin({ initial: false })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = mount()
    await hook._ready
    expect(hook.el.attrs["aria-pressed"]).toBe("false")

    hook.el.click()
    await flush()
    expect(plugin.requests).toEqual([true])
    expect(hook.el.attrs["aria-pressed"]).toBe("true")

    hook.el.click()
    await flush()
    expect(plugin.requests).toEqual([true, false])
    expect(hook.el.attrs["aria-pressed"]).toBe("false")
  })

  it("with a headset in, a tap does not claim the speaker", async () => {
    const plugin = speakerPlugin({ headset: true })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = mount()
    await hook._ready
    hook.el.click()
    await flush()
    expect(plugin.requests).toEqual([true])
    expect(hook.el.attrs["aria-pressed"]).toBe("false")
  })

  it("follows audioRouteChanged from the native call (route picker, AirPods)", async () => {
    const plugin = speakerPlugin({ initial: true })
    window.Capacitor = { Plugins: { SuiteMeetings: plugin } }
    const hook = mount()
    await hook._ready
    plugin.listeners.audioRouteChanged({ speaker: false })
    expect(hook.el.attrs["aria-pressed"]).toBe("false")
    plugin.listeners.audioRouteChanged({ speaker: true })
    expect(hook.el.attrs["aria-pressed"]).toBe("true")
  })
})
