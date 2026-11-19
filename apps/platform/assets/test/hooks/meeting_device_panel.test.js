import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { fakeDocument } from "../lib/fake_dom.js"
import { __resetForTests as resetClientState } from "../../js/client_state.js"
import { __resetForTests as resetOverlays } from "../../js/lib/dismissable_overlay.js"
import {
  DEVICE_FALLBACK_EVENT,
  DEVICES_CHANGED_EVENT,
  ACTIVE_DEVICE_EVENT,
  registerRoom,
  truncateMiddle,
  __resetForTests as resetDevices,
} from "../../js/lib/media_devices.js"
import MeetingDevicePanel, {
  MOVE_MS,
  OPEN_PANEL_EVENT,
  noticeText,
} from "../../js/hooks/meeting_device_panel.js"
import { getPreference } from "../../js/lib/media_devices.js"
import { asDeviceInfos } from "../lib/fake_media_devices.js"

/**
 * The "Sound and video" panel hook (task 01a1f4c5 stage 2).
 *
 * vitest runs in plain node: the panel frame `CallShell.call_controls/1`
 * renders is rebuilt below with `fake_dom.js`'s FakeElement, and the device
 * layer is the REAL `media_devices.js` over the REAL livekit-client, fed by a
 * stubbed `navigator.mediaDevices.enumerateDevices`. The output capability is
 * the real livekit check too: it asks a fresh `<audio>` for `setSinkId`, so
 * "unsupported" below is literally an audio element without `setSinkId`.
 */

const MICS = [
  { kind: "audioinput", deviceId: "default", label: "Default - AirPods Pro" },
  { kind: "audioinput", deviceId: "air-1", label: "AirPods Pro" },
  { kind: "audioinput", deviceId: "mbp-1", label: "MacBook Pro Microphone" },
  { kind: "audioinput", deviceId: "bh-1", label: "BlackHole 2ch" },
]
const CAMS = [
  { kind: "videoinput", deviceId: "cam-1", label: "FaceTime HD Camera" },
  { kind: "videoinput", deviceId: "cam-2", label: "Logitech BRIO 2 Ultra HD Pro Webcam" },
]
const OUTS = [
  { kind: "audiooutput", deviceId: "out-1", label: "AirPods Pro" },
  { kind: "audiooutput", deviceId: "out-2", label: "MacBook Pro Speakers" },
]

const settle = async () => {
  for (let i = 0; i < 8; i++) await Promise.resolve()
  await new Promise((r) => setTimeout(r, 0))
}

let doc
let body
let devices
let sinkSupported
let gum
let win

function fakeStorage() {
  const store = new Map()
  return {
    get length() {
      return store.size
    },
    key: (i) => Array.from(store.keys())[i] ?? null,
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  }
}

function h(tag, attrs = {}, children = []) {
  const n = doc.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v)
  for (const c of children) n.appendChild(c)
  return n
}

function section(panelId, kind, container) {
  return h("section", { "data-device-section": kind }, [
    h("h3", { id: `${panelId}-${kind}-label` }),
    h("div", {
      id: `${panelId}-${kind}-list`,
      role: "radiogroup",
      "data-device-list": kind,
      "data-container": container,
    }),
    h("p", { "data-device-status": kind, hidden: "" }),
    ...(kind === "audiooutput" ? [h("button", { "data-device-test-sound": "" })] : []),
  ])
}

function panel(id, container) {
  const kinds = ["audioinput", "videoinput", "audiooutput"]
  if (container === "sheet") {
    return h(
      "div",
      { id, "data-role": "meeting-device-panel", "data-container": "sheet", hidden: "" },
      [
        h("div", { "data-device-backdrop": "" }),
        h("div", { "data-device-card": "" }, [
          h("button", { "data-device-close": "" }),
          ...kinds.map((k) => section(id, k, container)),
        ]),
      ],
    )
  }
  return h(
    "div",
    { id, "data-role": "meeting-device-panel", "data-container": "popover", hidden: "" },
    kinds.map((k) => section(id, k, container)),
  )
}

// The markup call_controls renders with devices_id="devs".
function buildDom() {
  body = h("body")
  const root = h("div", { id: "devs", "data-role": "meeting-devices" }, [
    h("div", {
      id: "devs-notice",
      "data-role": "meeting-device-notice-slot",
      role: "status",
      "aria-live": "polite",
    }),
    panel("devs-popover", "popover"),
    panel("devs-sheet", "sheet"),
  ])
  const micToggle = h("button", {
    "data-role": "meeting-mic",
    "data-devices-toggle": "devs",
    "data-on": "true",
    "aria-label": "Mute microphone",
  })
  const micCaret = h("button", {
    "data-role": "call-control-mic-devices",
    "data-devices-for": "devs",
    "data-devices-container": "popover",
    "data-devices-section": "audioinput",
    "aria-expanded": "false",
  })
  const camCaret = h("button", {
    "data-role": "call-control-camera-devices",
    "data-devices-for": "devs",
    "data-devices-container": "popover",
    "data-devices-section": "videoinput",
    "aria-expanded": "false",
  })
  const phone = h("button", {
    "data-role": "call-control-devices",
    "data-devices-for": "devs",
    "data-devices-container": "sheet",
    "data-devices-section": "audioinput",
    "aria-expanded": "false",
  })
  const row = h("div", { "data-component": "call-controls" }, [micToggle, micCaret, camCaret, phone])
  body.appendChild(root)
  body.appendChild(row)
  return { root, micToggle, micCaret, camCaret, phone }
}

function mount() {
  const dom = buildDom()
  const hook = Object.create(MeetingDevicePanel)
  hook.el = dom.root
  hook.mounted()
  return { hook, ...dom }
}

// Bubble a click from `target` up through its ancestors, then the document.
function click(target) {
  for (let n = target; n && n.fire; n = n.parentNode) n.fire("click", { target, preventDefault() {} })
  doc.fire("click", { target, preventDefault() {} })
}

function rows(kind, container = "popover") {
  const list = body.querySelector(`[data-device-list="${kind}"][data-container="${container}"]`)
  return list.childNodes.filter((n) => n.getAttribute && n.getAttribute("role") === "radio")
}

function liveRows(kind, container) {
  return rows(kind, container).filter((r) => r.getAttribute("data-leaving") !== "true")
}

function fakeRoom(active = {}) {
  const map = new Map(Object.entries(active))
  return {
    switched: [],
    localParticipant: { getTrackPublication: () => null },
    getActiveDevice: (kind) => map.get(kind),
    switchActiveDevice(kind, deviceId, exact) {
      this.switched.push([kind, deviceId, exact])
      map.set(kind, deviceId)
      return Promise.resolve(true)
    },
  }
}

function fakeStream(label) {
  const track = { label, stopped: false, stop: vi.fn(function () { this.stopped = true }) }
  return { track, getTracks: () => [track] }
}

beforeEach(() => {
  resetClientState()
  resetDevices()
  resetOverlays()
  devices = [...MICS, ...CAMS, ...OUTS]
  sinkSupported = true
  gum = []

  doc = fakeDocument()
  const realCreate = doc.createElement
  doc.createElement = (tag) => {
    const n = realCreate(tag)
    if (tag === "audio" && sinkSupported) n.setSinkId = () => Promise.resolve()
    return n
  }
  doc.querySelectorAll = (sel) => body.querySelectorAll(sel)
  doc.querySelector = (sel) => body.querySelector(sel)

  win = new EventTarget()
  Object.assign(win, {
    innerWidth: 1280,
    innerHeight: 900,
    location: { href: "http://x/meetings/m" },
    history: { state: null, pushState: vi.fn(), back: vi.fn() },
    matchMedia: () => ({ matches: false }),
  })
  vi.stubGlobal("window", win)
  vi.stubGlobal("document", doc)
  vi.stubGlobal("localStorage", fakeStorage())
  vi.stubGlobal("navigator", {
    userAgent:
      "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    mediaDevices: {
      enumerateDevices: () => Promise.resolve(asDeviceInfos(devices)),
      getUserMedia: (c) => {
        const s = fakeStream(JSON.stringify(c))
        gum.push(s)
        return Promise.resolve(s)
      },
      addEventListener() {},
      removeEventListener() {},
    },
  })
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe("rows", () => {
  it("render from the device list, with tags, and the room's active device checked", async () => {
    registerRoom(fakeRoom({ audioinput: "air-1", videoinput: "cam-1" }), "meeting")
    const { hook, micCaret } = mount()
    await hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    await settle()

    const mics = rows("audioinput")
    expect(mics.map((r) => r.getAttribute("data-device-id"))).toEqual([
      "default",
      "air-1",
      "mbp-1",
      "bh-1",
    ])
    expect(mics.map((r) => r.getAttribute("aria-checked"))).toEqual([
      "false",
      "true",
      "false",
      "false",
    ])
    // Roving tabindex: the checked row is the one tab stop.
    expect(mics.map((r) => r.getAttribute("tabindex"))).toEqual(["-1", "0", "-1", "-1"])
    expect(mics[1].querySelector("[data-device-check]").getAttribute("class")).toContain("hero-check")
    expect(mics[1].querySelector("[data-device-label]").getAttribute("class")).toContain(
      "font-semibold",
    )
    expect(mics[0].querySelector('[data-device-tag="default"]')).not.toBeNull()
    expect(mics[3].querySelector('[data-device-tag="virtual"]')).not.toBeNull()
    expect(micCaret.getAttribute("aria-expanded")).toBe("true")
    expect(body.querySelector("#devs-popover").hasAttribute("hidden")).toBe(false)
  })

  it("truncates in the middle in the popover and keeps the whole name in the sheet", async () => {
    const { hook, micCaret, phone } = mount()
    await hook.open({ container: "popover", section: "videoinput", opener: micCaret })
    await settle()
    const brio = rows("videoinput")[1]
    const shown = brio.querySelector("[data-device-label]").textContent
    expect(shown).toBe(truncateMiddle("Logitech BRIO 2 Ultra HD Pro Webcam", 22))
    expect(shown.endsWith("Webcam")).toBe(true)
    expect(shown).toContain("…")
    expect(brio.getAttribute("aria-label")).toBe("Logitech BRIO 2 Ultra HD Pro Webcam")

    hook.close()
    await hook.open({ container: "sheet", section: "audioinput", opener: phone })
    await settle()
    const sheetBrio = rows("videoinput", "sheet")[1]
    const label = sheetBrio.querySelector("[data-device-label]")
    expect(label.textContent).toBe("Logitech BRIO 2 Ultra HD Pro Webcam")
    expect(label.getAttribute("class")).toContain("line-clamp-2")
  })

  it("a pick calls selectDevice: the registered room switches and the check moves", async () => {
    const room = fakeRoom({ audioinput: "air-1" })
    registerRoom(room, "meeting")
    const { hook, micCaret } = mount()
    await hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    await settle()

    click(rows("audioinput")[2])
    await settle()

    expect(room.switched).toEqual([["audioinput", "mbp-1", true]])
    expect(rows("audioinput").map((r) => r.getAttribute("aria-checked"))).toEqual([
      "false",
      "false",
      "true",
      "false",
    ])
  })

  it("a device removed while open disappears in place and the order never re-sorts", async () => {
    vi.useFakeTimers()
    const { hook, micCaret } = mount()
    const opening = hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    await vi.runAllTimersAsync()
    await opening
    const before = rows("audioinput")
    const [dflt, air, mbp, bh] = before

    // AirPods unplugged, and a USB mic arrives FIRST in enumeration order.
    devices = [
      { kind: "audioinput", deviceId: "usb-1", label: "USB Microphone" },
      ...devices.filter((d) => d.deviceId !== "air-1"),
    ]
    win.dispatchEvent(new CustomEvent(DEVICES_CHANGED_EVENT, { detail: { kind: "audioinput" } }))
    await vi.advanceTimersByTimeAsync(0)

    // Leaving, not yet gone: it fades out in place.
    expect(air.getAttribute("data-leaving")).toBe("true")
    await vi.advanceTimersByTimeAsync(MOVE_MS)

    const after = rows("audioinput")
    expect(after).not.toContain(air)
    // The survivors are the SAME nodes in the SAME order; the new one is
    // inserted next to its enumerated neighbour, not appended or sorted.
    expect(after.filter((r) => r !== after[0])).toEqual([dflt, mbp, bh])
    expect(after[0].getAttribute("data-device-id")).toBe("usb-1")
  })
})

describe("speaker", () => {
  it("SPEAKER is in the DOM with Test sound where setSinkId exists", () => {
    mount()
    expect(body.querySelectorAll('[data-device-section="audiooutput"]').length).toBe(2)
    expect(body.querySelectorAll("[data-device-test-sound]").length).toBe(2)
  })

  it("SPEAKER is REMOVED (not disabled) when the audio element has no setSinkId", () => {
    sinkSupported = false
    mount()
    expect(body.querySelectorAll('[data-device-section="audiooutput"]')).toEqual([])
    expect(body.querySelectorAll("[data-device-test-sound]")).toEqual([])
    expect(body.querySelectorAll('[data-device-list="audiooutput"]')).toEqual([])
    // The other sections are untouched.
    expect(body.querySelectorAll('[data-device-section="audioinput"]').length).toBe(2)
  })
})

describe("the device-switched strap", () => {
  const fallback = () =>
    win.dispatchEvent(
      new CustomEvent(DEVICE_FALLBACK_EVENT, {
        detail: { kind: "audioinput", fromLabel: "AirPods Pro", toLabel: "MacBook Pro Microphone" },
      }),
    )

  it("renders the exact copy in the polite live region above the controls", () => {
    mount()
    fallback()
    const strap = body.querySelector('[data-role="meeting-device-notice"]')
    expect(strap).not.toBeNull()
    expect(strap.querySelector("[data-notice-text]").textContent).toBe(
      "AirPods Pro disconnected. Now using MacBook Pro Microphone.",
    )
    expect(noticeText("AirPods Pro", "MacBook Pro Microphone")).toBe(
      "AirPods Pro disconnected. Now using MacBook Pro Microphone.",
    )
    const region = strap.closest('[aria-live="polite"]')
    expect(region).not.toBeNull()
    expect(region.getAttribute("role")).toBe("status")
    expect(region.getAttribute("data-role")).toBe("meeting-device-notice-slot")
    expect(strap.querySelector("[data-notice-change]").textContent).toBe("Change")
    expect(strap.querySelector("[data-notice-dismiss]").getAttribute("aria-label")).toBe("Dismiss")
  })

  it("is NOT removed by a timer: still there after 60s", async () => {
    vi.useFakeTimers()
    mount()
    fallback()
    await vi.advanceTimersByTimeAsync(60_000)
    expect(body.querySelector('[data-role="meeting-device-notice"]')).not.toBeNull()
  })

  it("is cleared by Dismiss, by opening the panel, and by the next active-device change", async () => {
    const { hook, micCaret } = mount()
    fallback()
    click(body.querySelector("[data-notice-dismiss]"))
    expect(body.querySelector('[data-role="meeting-device-notice"]')).toBeNull()

    fallback()
    await hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    expect(body.querySelector('[data-role="meeting-device-notice"]')).toBeNull()
    hook.close()

    fallback()
    win.dispatchEvent(
      new CustomEvent(ACTIVE_DEVICE_EVENT, { detail: { kind: "videoinput", deviceId: "cam-2" } }),
    )
    // A different kind does not clear a microphone strap.
    expect(body.querySelector('[data-role="meeting-device-notice"]')).not.toBeNull()
    win.dispatchEvent(
      new CustomEvent(ACTIVE_DEVICE_EVENT, { detail: { kind: "audioinput", deviceId: "air-1" } }),
    )
    expect(body.querySelector('[data-role="meeting-device-notice"]')).toBeNull()
  })

  it("leaves the new device's name on the mic toggle's aria-label and title", () => {
    const { micToggle } = mount()
    fallback()
    click(body.querySelector("[data-notice-dismiss]"))
    expect(micToggle.getAttribute("aria-label")).toBe("Mute microphone, MacBook Pro Microphone")
    expect(micToggle.getAttribute("title")).toBe("Microphone: MacBook Pro Microphone")
  })
})

describe("keyboard", () => {
  it("arrows move the roving tab stop, Enter selects, Esc closes and returns focus to the opener", async () => {
    const room = fakeRoom({ audioinput: "air-1" })
    registerRoom(room, "meeting")
    const { hook, micCaret } = mount()
    await hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    await settle()
    const pop = body.querySelector("#devs-popover")
    const mics = rows("audioinput")
    // Opens focused on the checked row of the caret's section.
    expect(doc.activeElement).toBe(mics[1])

    pop.fire("keydown", { key: "ArrowDown", target: mics[1], preventDefault() {} })
    expect(doc.activeElement).toBe(mics[2])
    expect(mics.map((r) => r.getAttribute("tabindex"))).toEqual(["-1", "-1", "0", "-1"])
    // Moving does NOT switch the device.
    expect(room.switched).toEqual([])

    pop.fire("keydown", { key: "Enter", target: mics[2], preventDefault() {} })
    await settle()
    expect(room.switched).toEqual([["audioinput", "mbp-1", true]])

    win.dispatchEvent(Object.assign(new Event("keydown"), { key: "Escape" }))
    expect(hook.isOpen()).toBe(false)
    expect(pop.hasAttribute("hidden")).toBe(true)
    expect(micCaret.getAttribute("aria-expanded")).toBe("false")
    expect(doc.activeElement).toBe(micCaret)
  })
})

// A history that behaves like Chrome's: pushState is synchronous and drops
// forward entries; back() is ASYNCHRONOUS and resolves against the entry
// current when it was CALLED, then fires popstate. The vi.fn history above
// cannot show the stage 5 bug, where a close-then-reopen left the next Esc
// going back off the meeting page.
function chromeHistory(w, urls) {
  const entries = urls.map((url) => ({ url, state: null }))
  let index = entries.length - 1
  const history = {
    calls: { push: 0, back: 0 },
    get length() {
      return entries.length
    },
    get state() {
      return entries[index].state
    },
    get index() {
      return index
    },
    pushState(state, _title, url) {
      history.calls.push += 1
      entries.splice(index + 1)
      entries.push({ url: url || entries[index].url, state })
      index = entries.length - 1
    },
    back() {
      history.calls.back += 1
      const target = Math.max(0, index - 1)
      setTimeout(() => {
        if (target === index) return
        index = target
        w.dispatchEvent(new Event("popstate"))
      }, 0)
    },
  }
  w.history = history
  w.location = {
    get href() {
      return entries[index].url
    },
  }
  return history
}

describe("switching carets with the popover open (stage 5 review)", () => {
  async function openMicThenCamera() {
    const history = chromeHistory(win, ["http://x/previous", "http://x/meetings/m"])
    const room = fakeRoom({ audioinput: "air-1", videoinput: "cam-1" })
    registerRoom(room, "meeting")
    const dom = mount()
    click(dom.micCaret)
    await settle()
    const lengthAfterOpen = history.length
    history.calls.push = 0
    history.calls.back = 0
    click(dom.camCaret)
    await settle()
    return { history, room, lengthAfterOpen, ...dom }
  }

  it("reuses the open layer: the popover is on CAMERA, focused there, and no history moved", async () => {
    const { hook, history, lengthAfterOpen, micCaret, camCaret } = await openMicThenCamera()
    expect(hook.isOpen()).toBe(true)
    expect(history.length).toBe(lengthAfterOpen)
    // Not a close and a reopen: no back(), no second entry.
    expect(history.calls).toEqual({ push: 0, back: 0 })
    expect(micCaret.getAttribute("aria-expanded")).toBe("false")
    expect(camCaret.getAttribute("aria-expanded")).toBe("true")
    expect(doc.activeElement).toBe(rows("videoinput")[0])
  })

  it("then Esc closes the popover and stays on the meeting page", async () => {
    const { hook, history, room, lengthAfterOpen, camCaret } = await openMicThenCamera()

    win.dispatchEvent(Object.assign(new Event("keydown"), { key: "Escape" }))
    await settle()
    await settle()

    expect(hook.isOpen()).toBe(false)
    expect(win.location.href).toBe("http://x/meetings/m")
    expect(history.index).toBe(1)
    expect(history.length).toBe(lengthAfterOpen)
    expect(doc.activeElement).toBe(camCaret)
    // The call is still up: the room the panel drives is still registered.
    expect(hook._room()).toBe(room)

    // And the NEXT open and Esc still stay put.
    click(camCaret)
    await settle()
    win.dispatchEvent(Object.assign(new Event("keydown"), { key: "Escape" }))
    await settle()
    await settle()
    expect(win.location.href).toBe("http://x/meetings/m")
  })

  it("then an outside click closes the popover and stays on the meeting page", async () => {
    const { hook, history, room, lengthAfterOpen } = await openMicThenCamera()

    doc.fire("pointerdown", { target: body })
    await settle()
    await settle()

    expect(hook.isOpen()).toBe(false)
    expect(win.location.href).toBe("http://x/meetings/m")
    expect(history.index).toBe(1)
    expect(history.length).toBe(lengthAfterOpen)
    expect(hook._room()).toBe(room)
  })
})

describe("pick by proof", () => {
  it("every preview stream it captured is stopped on close", async () => {
    const { hook, micCaret } = mount()
    await hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    await settle()
    // The active mic (no room: the resolved default) gets a capture for its
    // meter; hovering another mic and another camera opens probes.
    rows("audioinput")[2].fire("mouseenter")
    rows("videoinput")[1].fire("mouseenter")
    await settle()
    expect(gum.length).toBe(3)
    expect(gum.some((s) => s.track.label.includes('"exact":"mbp-1"'))).toBe(true)
    expect(gum.some((s) => s.track.label.includes('"exact":"cam-2"'))).toBe(true)
    expect(gum.every((s) => !s.track.stopped)).toBe(true)

    hook.close()
    expect(gum.every((s) => s.track.stop.mock.calls.length === 1)).toBe(true)
    expect(body.querySelectorAll("[data-device-meter]")).toEqual([])
    expect(body.querySelectorAll("[data-device-thumb]")).toEqual([])
  })

  it("a capture that resolves after close is stopped, and destroyed stops everything", async () => {
    let release
    navigator.mediaDevices.getUserMedia = () =>
      new Promise((r) => {
        release = () => {
          const s = fakeStream("late")
          gum.push(s)
          r(s)
        }
      })
    const { hook, micCaret } = mount()
    await hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    await settle()
    hook.destroyed()
    release()
    await settle()
    expect(gum.length).toBe(1)
    expect(gum[0].track.stop).toHaveBeenCalledTimes(1)
  })

  it("never stops the PUBLISHED track it shows on the active camera row", async () => {
    const published = { readyState: "live", stop: vi.fn() }
    const room = fakeRoom({ videoinput: "cam-1", audioinput: "air-1" })
    room.localParticipant.getTrackPublication = (source) =>
      source === "camera" || source === "microphone" ? { track: { mediaStreamTrack: published } } : null
    registerRoom(room, "meeting")
    vi.stubGlobal(
      "MediaStream",
      class {
        constructor(tracks) {
          this.tracks = tracks
        }
        getTracks() {
          return this.tracks
        }
      },
    )
    const { hook, camCaret } = mount()
    await hook.open({ container: "popover", section: "videoinput", opener: camCaret })
    await settle()
    // No second capture for the active camera or the active mic.
    expect(gum.length).toBe(0)
    expect(rows("videoinput")[0].querySelector("[data-device-thumb]")).not.toBeNull()
    hook.close()
    expect(published.stop).not.toHaveBeenCalled()
  })
})

// ── the lobby's Change links (task 01a1f4c5 stage 3) ──────────────────
describe("the lobby: an auto trigger, the inline accordion and the sheet", () => {
  function inlinePanel(id) {
    const kinds = ["audioinput", "videoinput", "audiooutput"]
    return h(
      "div",
      { id, "data-role": "meeting-device-panel", "data-container": "inline", hidden: "" },
      kinds.map((k) => section(id, k, "inline")),
    )
  }

  // The markup `DevicePanel.lobby_devices/1` renders.
  function mountLobby() {
    body = h("body")
    const root = h("div", { id: "lp", "data-role": "meeting-devices" }, [
      inlinePanel("lp-inline"),
      panel("lp-sheet", "sheet"),
    ])
    const change = {}
    const rowsEl = h(
      "div",
      {},
      ["audioinput", "videoinput", "audiooutput"].map((kind) => {
        change[kind] = h("button", {
          "data-role": "meeting-lobby-device-change",
          "data-devices-for": "lp",
          "data-devices-container": "auto",
          "data-devices-section": kind,
          "aria-expanded": "false",
        })
        return change[kind]
      }),
    )
    body.appendChild(rowsEl)
    body.appendChild(root)
    const hook = Object.create(MeetingDevicePanel)
    hook.el = root
    hook.mounted()
    return { hook, root, change }
  }

  const inline = () => body.querySelector("#lp-inline")
  const sheet = () => body.querySelector("#lp-sheet")
  const visibleSections = () =>
    inline()
      .querySelectorAll("[data-device-section]")
      .filter((s) => !s.hasAttribute("hidden"))
      .map((s) => s.getAttribute("data-device-section"))

  it("at sm and up, Change expands ONE section inline, with no history layer", async () => {
    win.matchMedia = (q) => ({ matches: q === "(min-width: 640px)" })
    const { change } = mountLobby()
    click(change.videoinput)
    await settle()

    expect(inline().hasAttribute("hidden")).toBe(false)
    expect(sheet().hasAttribute("hidden")).toBe(true)
    expect(visibleSections()).toEqual(["videoinput"])
    expect(liveRows("videoinput", "inline").map((r) => r.getAttribute("data-device-id"))).toEqual([
      "cam-1",
      "cam-2",
    ])
    // The hidden sections were not rendered (no capture for a hidden mic).
    expect(rows("audioinput", "inline")).toEqual([])
    expect(change.videoinput.getAttribute("aria-expanded")).toBe("true")
    expect(win.history.pushState).not.toHaveBeenCalled()

    // An outside pointerdown does not collapse an accordion.
    doc.fire("pointerdown", { target: body })
    expect(inline().hasAttribute("hidden")).toBe(false)

    // The other Change switches the section; the same one collapses.
    click(change.audioinput)
    await settle()
    expect(visibleSections()).toEqual(["audioinput"])
    expect(change.videoinput.getAttribute("aria-expanded")).toBe("false")
    click(change.audioinput)
    expect(inline().hasAttribute("hidden")).toBe(true)
    expect(change.audioinput.getAttribute("aria-expanded")).toBe("false")
  })

  it("below sm, the same Change opens the bottom sheet", async () => {
    win.matchMedia = () => ({ matches: false })
    const { change } = mountLobby()
    click(change.audioinput)
    await settle()
    expect(sheet().hasAttribute("hidden")).toBe(false)
    expect(inline().hasAttribute("hidden")).toBe(true)
    expect(liveRows("audioinput", "sheet")).toHaveLength(4)
  })

  it("Esc inside the inline section collapses it and returns focus to Change", async () => {
    win.matchMedia = (q) => ({ matches: q === "(min-width: 640px)" })
    const { change } = mountLobby()
    click(change.audioinput)
    await settle()
    const first = liveRows("audioinput", "inline")[0]
    first.focus()
    inline().fire("keydown", { key: "Escape", target: first, preventDefault() {} })
    expect(inline().hasAttribute("hidden")).toBe(true)
    expect(doc.activeElement).toBe(change.audioinput)
  })

  it("meeting:device-panel-open expands MICROPHONE inline without moving focus", async () => {
    const { change } = mountLobby()
    const elsewhere = h("input")
    elsewhere.focus()
    win.dispatchEvent(
      new CustomEvent(OPEN_PANEL_EVENT, {
        detail: { id: "lp", container: "inline", section: "audioinput" },
      }),
    )
    await settle()
    expect(visibleSections()).toEqual(["audioinput"])
    expect(change.audioinput.getAttribute("aria-expanded")).toBe("true")
    expect(doc.activeElement).toBe(elsewhere)

    // Another panel's id is not ours.
    win.dispatchEvent(
      new CustomEvent(OPEN_PANEL_EVENT, { detail: { id: "other", container: "inline", section: "videoinput" } }),
    )
    await settle()
    expect(visibleSections()).toEqual(["audioinput"])
  })

  it("a pick in the lobby only persists (no room) and announces the device", async () => {
    win.matchMedia = (q) => ({ matches: q === "(min-width: 640px)" })
    const seen = []
    win.addEventListener(ACTIVE_DEVICE_EVENT, (e) => seen.push(e.detail))
    const { change } = mountLobby()
    click(change.audioinput)
    await settle()
    const bh = liveRows("audioinput", "inline").find((r) => r.getAttribute("data-device-id") === "bh-1")
    click(bh)
    await settle()
    expect(seen.at(-1)).toMatchObject({ kind: "audioinput", deviceId: "bh-1" })
    expect(getPreference("audioinput")).toEqual({ deviceId: "bh-1", label: "BlackHole 2ch" })
    expect(bh.getAttribute("aria-checked")).toBe("true")
  })
})

// ── the compact surfaces (task 01a1f4c5 stage 4) ─────────────────────────
//
// The markup MeetingBarLive renders: the panel root is a SIBLING of the bar
// (`data-devices-notice="when-alone"`, a `meeting-bar-device-notice` slot,
// popover + sheet) and the bar's carets open the popover BELOW themselves.

function buildBarDom() {
  const root = h(
    "div",
    { id: "bar-devs", "data-role": "meeting-devices", "data-devices-notice": "when-alone" },
    [
      h("div", {
        id: "bar-devs-notice",
        "data-role": "meeting-bar-device-notice",
        role: "status",
        "aria-live": "polite",
      }),
      panel("bar-devs-popover", "popover"),
      panel("bar-devs-sheet", "sheet"),
    ],
  )
  const caret = (kind, flag) =>
    h("button", {
      [flag]: "",
      "data-devices-for": "bar-devs",
      "data-devices-container": "popover",
      "data-devices-section": kind,
      "data-devices-placement": "below",
      "aria-expanded": "false",
    })
  const micCaret = caret("audioinput", "data-bar-mic-devices")
  const camCaret = caret("videoinput", "data-bar-camera-devices")
  const bar = h("div", { id: "meeting-top-bar" }, [micCaret, camCaret])
  return { root, bar, micCaret, camCaret }
}

function mountBarPanel({ withCallControls = false } = {}) {
  let call = null
  if (withCallControls) {
    call = mount()
  } else {
    body = h("body")
  }
  const dom = buildBarDom()
  body.appendChild(dom.bar)
  body.appendChild(dom.root)
  const hook = Object.create(MeetingDevicePanel)
  hook.el = dom.root
  hook.mounted()
  return { hook, call, ...dom }
}

const barFallback = (detail = {}) =>
  win.dispatchEvent(
    new CustomEvent(DEVICE_FALLBACK_EVENT, {
      detail: { kind: "audioinput", fromLabel: "AirPods Pro", toLabel: "MacBook Pro Microphone", ...detail },
    }),
  )

describe("the top bar's panel", () => {
  it("opens the popover BELOW the caret (the bar is at the top of the page)", async () => {
    const { micCaret } = mountBarPanel()
    micCaret.getBoundingClientRect = () => ({ left: 600, top: 8, bottom: 36, right: 630 })
    click(micCaret)
    await settle()

    const pop = body.querySelector("#bar-devs-popover")
    expect(pop.hasAttribute("hidden")).toBe(false)
    expect(pop.style.top).toBe("44px")
    expect(pop.style.bottom).toBe("")
    expect(micCaret.getAttribute("aria-expanded")).toBe("true")
  })

  it("renders the strap under the bar, in meeting-bar-device-notice, polite and untimed", async () => {
    vi.useFakeTimers()
    mountBarPanel()
    barFallback({ surface: "meeting" })
    const strap = body.querySelector('[data-role="meeting-device-notice"]')
    expect(strap).not.toBeNull()
    const region = strap.closest('[aria-live="polite"]')
    expect(region.getAttribute("data-role")).toBe("meeting-bar-device-notice")
    expect(strap.querySelector("[data-notice-text]").textContent).toBe(
      "AirPods Pro disconnected. Now using MacBook Pro Microphone.",
    )
    await vi.advanceTimersByTimeAsync(60_000)
    expect(body.querySelector('[data-role="meeting-device-notice"]')).not.toBeNull()
  })

  it("gives way to a call surface's own strap on the same page: one fallback, one strap", () => {
    mountBarPanel({ withCallControls: true })
    barFallback({ surface: "meeting" })
    const straps = body.querySelectorAll('[data-role="meeting-device-notice"]')
    expect(straps).toHaveLength(1)
    expect(straps[0].closest('[aria-live="polite"]').getAttribute("data-role")).toBe(
      "meeting-device-notice-slot",
    )
  })

  it("Change with no visible trigger (the phone strip) opens the sheet", async () => {
    const { micCaret, camCaret } = mountBarPanel()
    micCaret.getClientRects = () => []
    camCaret.getClientRects = () => []
    barFallback({ surface: "meeting" })
    click(body.querySelector("[data-notice-change]"))
    await settle()
    expect(body.querySelector("#bar-devs-sheet").hasAttribute("hidden")).toBe(false)
    expect(body.querySelector("#bar-devs-popover").hasAttribute("hidden")).toBe(true)
  })
})

describe("a panel drives its own surface's room only", () => {
  it("a fallback in the Voice tab's room shows no strap on a meeting panel", () => {
    mount()
    barFallback({ surface: "voice" })
    expect(body.querySelector('[data-role="meeting-device-notice"]')).toBeNull()
    barFallback({ surface: "meeting" })
    expect(body.querySelector('[data-role="meeting-device-notice"]')).not.toBeNull()
  })

  it("a voice-surface panel switches the voice room, never the meeting room", async () => {
    const meeting = fakeRoom({ audioinput: "air-1" })
    const voice = fakeRoom({ audioinput: "air-1" })
    registerRoom(voice, "voice")
    registerRoom(meeting, "meeting")
    const { hook, root, micCaret } = mount()
    root.setAttribute("data-devices-surface", "voice")
    await hook.open({ container: "popover", section: "audioinput", opener: micCaret })
    await settle()
    click(rows("audioinput")[2])
    await settle()
    expect(voice.switched).toEqual([["audioinput", "mbp-1", true]])
    expect(meeting.switched).toEqual([])
  })
})
