import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import MeetingLobbyPreview, {
  DIGITAL_SILENCE_MS,
  FLAT_WARN_MS,
  HEARD_FADE_MS,
  METER_MS,
} from "../../js/hooks/meeting_lobby_preview.js"
import { OPEN_PANEL_EVENT } from "../../js/hooks/meeting_device_panel.js"
import { fakeDocument } from "../lib/fake_dom.js"
import { ClientState, __resetForTests as resetClientState } from "../../js/client_state.js"
import {
  ACTIVE_DEVICE_EVENT,
  selectDevice,
  truncateMiddle,
  __resetForTests,
} from "../../js/lib/media_devices.js"

/**
 * `MeetingLobbyPreview` (task 01a07410 / FE-17 stage 4) mirrors the
 * server's `data-camera-enabled` into ONE local getUserMedia preview. It
 * owns the stream and nothing else: it never pushes an event and never
 * decides media state, so these tests are about start/stop hygiene —
 * the camera light must follow the toggle, and must go out on destroy.
 */

function fakeTrack() {
  return { stopped: false, stop() { this.stopped = true } }
}

function fakeStream() {
  const tracks = [fakeTrack()]
  return { tracks, getTracks: () => tracks }
}

function buildEl(cameraEnabled) {
  const video = { srcObject: undefined, play: () => Promise.resolve() }
  // Mirrors the server-rendered element, which ships `data-preview="off"`.
  return {
    dataset: { cameraEnabled: String(cameraEnabled), preview: "off" },
    _video: video,
    querySelector(sel) {
      return sel === "video" ? video : null
    },
  }
}

function buildHook(el) {
  const hook = Object.create(MeetingLobbyPreview)
  hook.el = el
  return hook
}

async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 0))
}

describe("MeetingLobbyPreview", () => {
  let priorNavigator
  let requests
  let streams

  beforeEach(() => {
    priorNavigator = globalThis.navigator
    requests = []
    streams = []
    Object.defineProperty(globalThis, "navigator", {
      configurable: true,
      value: {
        mediaDevices: {
          getUserMedia(constraints) {
            requests.push(constraints)
            const s = fakeStream()
            streams.push(s)
            return Promise.resolve(s)
          },
        },
      },
    })
  })

  afterEach(() => {
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: priorNavigator })
  })

  it("starts a video-only preview at mount when the camera is on", async () => {
    const el = buildEl(true)
    const hook = buildHook(el)

    hook.mounted()
    await settle()

    expect(requests).toEqual([{ video: true, audio: false }])
    expect(el._video.srcObject).toBe(streams[0])
    expect(el.dataset.preview).toBe("live")
  })

  it("does not ask for the camera at mount when the toggle is off", async () => {
    const el = buildEl(false)
    const hook = buildHook(el)

    hook.mounted()
    await settle()

    expect(requests).toEqual([])
    expect(el.dataset.preview).toBe("off")
  })

  it("stops the stream when the toggle flips off, and restarts when it flips on", async () => {
    const el = buildEl(true)
    const hook = buildHook(el)
    hook.mounted()
    await settle()

    el.dataset.cameraEnabled = "false"
    hook.updated()
    await settle()

    expect(streams[0].tracks[0].stopped).toBe(true)
    expect(el._video.srcObject).toBeNull()
    expect(el.dataset.preview).toBe("off")

    el.dataset.cameraEnabled = "true"
    hook.updated()
    await settle()

    expect(requests).toHaveLength(2)
    expect(el._video.srcObject).toBe(streams[1])
    expect(el.dataset.preview).toBe("live")
  })

  it("does not open a second stream on a repaint while one is live", async () => {
    const el = buildEl(true)
    const hook = buildHook(el)
    hook.mounted()
    await settle()

    hook.updated()
    hook.updated()
    await settle()

    expect(requests).toHaveLength(1)
  })

  it("releases the camera on destroyed", async () => {
    const el = buildEl(true)
    const hook = buildHook(el)
    hook.mounted()
    await settle()

    hook.destroyed()

    expect(streams[0].tracks[0].stopped).toBe(true)
    expect(el._video.srcObject).toBeNull()
  })

  it("marks the tile unavailable when getUserMedia refuses, without throwing", async () => {
    const el = buildEl(true)
    const hook = buildHook(el)
    globalThis.navigator.mediaDevices.getUserMedia = () =>
      Promise.reject(new Error("NotAllowedError"))
    const priorWarn = console.warn
    console.warn = () => {}
    try {
      hook.mounted()
      await settle()
    } finally {
      console.warn = priorWarn
    }

    expect(el.dataset.preview).toBe("unavailable")
    expect(el._video.srcObject).toBeUndefined()
  })

  // ── the chosen camera (task 01a1f4c5 stage 1) ────────────────────────
  describe("the chosen camera", () => {
    beforeEach(() => {
      resetClientState()
      __resetForTests()
      const store = new Map()
      vi.stubGlobal("localStorage", {
        get length() {
          return store.size
        },
        key: (i) => Array.from(store.keys())[i] ?? null,
        getItem: (k) => (store.has(k) ? store.get(k) : null),
        setItem: (k, v) => store.set(k, String(v)),
        removeItem: (k) => store.delete(k),
      })
      vi.stubGlobal("window", new EventTarget())
    })

    afterEach(() => {
      vi.unstubAllGlobals()
    })

    it("opens the remembered camera, NON-exact", async () => {
      ClientState.set("meeting_devices", "videoinput", { deviceId: "brio-1", label: "Logitech BRIO 2" })
      const el = buildEl(true)
      buildHook(el).mounted()
      await settle()
      expect(requests).toEqual([{ video: { deviceId: "brio-1" }, audio: false }])
    })

    it("re-acquires on meeting:active-device for videoinput, and stops the old stream", async () => {
      const el = buildEl(true)
      const hook = buildHook(el)
      hook.mounted()
      await settle()

      await selectDevice("videoinput", "brio-1", { room: null })
      await settle()

      expect(streams[0].tracks[0].stopped).toBe(true)
      expect(requests.at(-1)).toEqual({ video: { deviceId: "brio-1" }, audio: false })
      expect(el._video.srcObject).toBe(streams.at(-1))
      expect(el.dataset.preview).toBe("live")
    })

    it("ignores a microphone change, and stops listening once destroyed", async () => {
      const el = buildEl(true)
      const hook = buildHook(el)
      hook.mounted()
      await settle()

      window.dispatchEvent(new CustomEvent(ACTIVE_DEVICE_EVENT, { detail: { kind: "audioinput" } }))
      await settle()
      expect(requests).toHaveLength(1)

      hook.destroyed()
      window.dispatchEvent(new CustomEvent(ACTIVE_DEVICE_EVENT, { detail: { kind: "videoinput" } }))
      await settle()
      expect(requests).toHaveLength(1)
    })
  })
})

// ── "You'll join with", the mic stream and the mic check (task 01a1f4c5
// stage 3) ──────────────────────────────────────────────────────────────
//
// The block `DevicePanel.lobby_devices/1` renders is rebuilt with
// fake_dom.js's FakeElement. The device layer is the REAL media_devices.js
// over the REAL livekit-client, fed by a stubbed enumerateDevices; the
// analyser is a stub whose samples each test sets.
describe("the lobby's You'll join with block", () => {
  const MICS = [
    { kind: "audioinput", deviceId: "default", label: "Default - AirPods Pro" },
    { kind: "audioinput", deviceId: "air-1", label: "AirPods Pro" },
    { kind: "audioinput", deviceId: "bh-1", label: "BlackHole 2ch" },
  ]
  const CAMS = [
    { kind: "videoinput", deviceId: "cam-1", label: "FaceTime HD Camera" },
    { kind: "videoinput", deviceId: "cam-2", label: "Logitech BRIO 2 Ultra HD Pro Webcam" },
  ]
  const OUTS = [
    { kind: "audiooutput", deviceId: "default", label: "Default - AirPods Pro" },
    { kind: "audiooutput", deviceId: "out-2", label: "MacBook Pro Speakers" },
  ]

  let doc
  let body
  let devices
  let sinkSupported
  let gum
  let samples // "flat" | "zero" | "loud"
  let ctxState
  let contexts
  let opened

  const flush = async () => {
    for (let i = 0; i < 20; i++) await Promise.resolve()
    await vi.advanceTimersByTimeAsync(0)
  }

  function h(tag, attrs = {}, children = []) {
    const n = doc.createElement(tag)
    for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v)
    for (const c of children) n.appendChild(c)
    return n
  }

  function row(kind) {
    const parts = [
      h("span", { "data-lobby-device-alert": "", hidden: "" }),
      h("span", { "data-lobby-device-label": "" }),
    ]
    if (kind === "audioinput") {
      parts.push(
        h(
          "span",
          { "data-lobby-meter": "", hidden: "" },
          [1, 2, 3, 4, 5].map(() => h("i", { "data-meter-bar": "" })),
        ),
      )
    }
    if (kind === "audiooutput") parts.push(h("button", { "data-lobby-test-sound": "" }))
    parts.push(
      h("button", {
        "data-role": "meeting-lobby-device-change",
        "data-devices-for": "meeting-lobby-devices-panel",
        "data-devices-container": "auto",
        "data-devices-section": kind,
      }),
    )
    return h("div", { "data-lobby-device": kind }, [
      h("div", { "data-role": "meeting-lobby-device-row", "data-kind": kind }, parts),
      h("p", { "data-role": "meeting-lobby-device-substituted", "data-kind": kind, hidden: "" }),
    ])
  }

  function checkLine() {
    return h("p", { "data-role": "meeting-lobby-mic-check", "data-state": "off", hidden: "" }, [
      h("span", { "data-mic-check-icon": "heard", hidden: "" }),
      h("span", { "data-mic-check-icon": "warning", hidden: "" }),
      h("span", { "data-mic-check-copy": "invitation", hidden: "" }),
      h("span", { "data-mic-check-copy": "heard", hidden: "" }),
      h("span", { "data-mic-check-copy": "warning", hidden: "" }),
    ])
  }

  function mountLobby({ camera = true, mic = true } = {}) {
    body = h("body")
    const video = h("video")
    video.play = () => Promise.resolve()
    const preview = h(
      "div",
      {
        id: "meeting-lobby-preview",
        "data-camera-enabled": String(camera),
        "data-mic-enabled": String(mic),
        "data-preview": "off",
      },
      [video],
    )
    const block = h("section", { "data-role": "meeting-lobby-devices" }, [
      h("div", { id: "meeting-lobby-devices-rows" }, [
        row("audioinput"),
        row("videoinput"),
        row("audiooutput"),
        checkLine(),
      ]),
      h("div", { id: "meeting-lobby-devices-panel", "data-role": "meeting-devices" }),
    ])
    body.appendChild(preview)
    body.appendChild(block)
    const hook = Object.create(MeetingLobbyPreview)
    hook.el = preview
    hook.mounted()
    return { hook, preview, block, video }
  }

  const q = (sel) => body.querySelector(sel)
  const label = (kind) =>
    q(`[data-lobby-device="${kind}"]`).querySelector("[data-lobby-device-label]").textContent
  const substituted = (kind) =>
    q(`[data-lobby-device="${kind}"]`).querySelector(
      '[data-role="meeting-lobby-device-substituted"]',
    )
  const check = () => q('[data-role="meeting-lobby-mic-check"]')
  const shownCopy = () =>
    check()
      .querySelectorAll("[data-mic-check-copy]")
      .filter((n) => !n.hasAttribute("hidden"))
      .map((n) => n.getAttribute("data-mic-check-copy"))
  const micStreams = () => gum.filter((s) => s.constraints.audio)
  const camStreams = () => gum.filter((s) => s.constraints.video)

  class FakeAnalyser {
    constructor() {
      this.fftSize = 512
    }
    getFloatTimeDomainData(data) {
      for (let i = 0; i < data.length; i++) {
        if (samples === "zero") data[i] = 0
        else if (samples === "loud") data[i] = i % 2 ? 0.3 : -0.3
        // A quiet room: real, non-zero, well under the noise floor.
        else data[i] = i % 2 ? 0.004 : -0.004
      }
    }
  }

  class FakeAudioContext {
    constructor() {
      this.state = ctxState
      this.closed = false
      contexts.push(this)
    }
    createMediaStreamSource() {
      return { connect() {}, disconnect() {} }
    }
    createAnalyser() {
      return new FakeAnalyser()
    }
    resume() {
      return Promise.resolve()
    }
    close() {
      this.closed = true
    }
  }

  beforeEach(() => {
    vi.useFakeTimers()
    resetClientState()
    __resetForTests()
    devices = [...MICS, ...CAMS, ...OUTS]
    sinkSupported = true
    gum = []
    samples = "flat"
    ctxState = "running"
    contexts = []
    opened = []

    doc = fakeDocument()
    const realCreate = doc.createElement
    doc.createElement = (tag) => {
      const n = realCreate(tag)
      if (tag === "audio" && sinkSupported) n.setSinkId = () => Promise.resolve()
      return n
    }
    doc.querySelector = (sel) => body.querySelector(sel)
    doc.querySelectorAll = (sel) => body.querySelectorAll(sel)

    const store = new Map()
    vi.stubGlobal("localStorage", {
      get length() {
        return store.size
      },
      key: (i) => Array.from(store.keys())[i] ?? null,
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => store.set(k, String(v)),
      removeItem: (k) => store.delete(k),
    })
    const win = new EventTarget()
    win.AudioContext = FakeAudioContext
    win.addEventListener(OPEN_PANEL_EVENT, (e) => opened.push(e.detail))
    vi.stubGlobal("window", win)
    vi.stubGlobal("document", doc)
    vi.stubGlobal("navigator", {
      userAgent:
        "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
      mediaDevices: {
        enumerateDevices: () => Promise.resolve(devices.map((d) => ({ ...d }))),
        getUserMedia: (constraints) => {
          const track = { stopped: false, stop: vi.fn(function () { this.stopped = true }) }
          const s = { constraints, track, getTracks: () => [track] }
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

  // ── which device ──────────────────────────────────────────────────

  it("names each kind's device; the camera preview opens the remembered camera", async () => {
    ClientState.set("meeting_devices", "videoinput", { deviceId: "cam-2", label: "Logitech BRIO 2 Ultra HD Pro Webcam" })
    mountLobby()
    await flush()

    expect(camStreams()[0].constraints).toEqual({ video: { deviceId: "cam-2" }, audio: false })
    expect(label("audioinput")).toBe("Default - AirPods Pro")
    // Middle-truncated past LOBBY_LABEL_CHARS? No: 35 chars is one over.
    expect(label("videoinput")).toBe(truncateMiddle("Logitech BRIO 2 Ultra HD Pro Webcam", 34))
    expect(label("audiooutput")).toBe("Default - AirPods Pro")
    for (const kind of ["audioinput", "videoinput", "audiooutput"]) {
      expect(substituted(kind).hasAttribute("hidden")).toBe(true)
    }
  })

  it("shows the remembered-device line when the stored device is absent by id AND label", async () => {
    ClientState.set("meeting_devices", "audioinput", { deviceId: "usb-9", label: "Shure MV7" })
    mountLobby()
    await flush()

    expect(substituted("audioinput").hasAttribute("hidden")).toBe(false)
    // The row names the substitute.
    expect(label("audioinput")).toBe("Default - AirPods Pro")
    expect(substituted("videoinput").hasAttribute("hidden")).toBe(true)
  })

  it("matches a rotated deviceId by label: no remembered-device line", async () => {
    ClientState.set("meeting_devices", "audioinput", { deviceId: "stale-id", label: "BlackHole 2ch" })
    mountLobby()
    await flush()

    expect(label("audioinput")).toBe("BlackHole 2ch")
    expect(substituted("audioinput").hasAttribute("hidden")).toBe(true)
    expect(micStreams()[0].constraints).toEqual({ audio: { deviceId: "bh-1" }, video: false })
  })

  it("removes the speaker row (not disabled) where the browser cannot choose an output", async () => {
    sinkSupported = false
    mountLobby()
    await flush()
    expect(q('[data-lobby-device="audiooutput"]')).toBeNull()
    expect(q("[data-lobby-test-sound]")).toBeNull()
    expect(q('[data-lobby-device="audioinput"]')).not.toBeNull()
  })

  it("says the microphone is blocked when the browser refused it", async () => {
    devices = []
    navigator.mediaDevices.getUserMedia = (c) =>
      c.audio
        ? Promise.reject(Object.assign(new Error("denied"), { name: "NotAllowedError" }))
        : Promise.resolve({ getTracks: () => [] })
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
    mountLobby()
    await flush()
    warn.mockRestore()

    expect(label("audioinput")).toBe("Microphone blocked by browser")
    expect(
      q('[data-lobby-device="audioinput"]').querySelector("[data-lobby-device-alert]").hasAttribute("hidden"),
    ).toBe(false)
    expect(check().hasAttribute("hidden")).toBe(true)
  })

  // ── the mic stream ────────────────────────────────────────────────

  it("opens the mic stream only while data-mic-enabled is true", async () => {
    const { hook, preview } = mountLobby({ mic: false })
    await flush()
    expect(micStreams()).toEqual([])
    expect(q("[data-lobby-meter]").hasAttribute("hidden")).toBe(true)
    expect(check().hasAttribute("hidden")).toBe(true)

    preview.setAttribute("data-mic-enabled", "true")
    hook.updated()
    await flush()
    expect(micStreams()).toHaveLength(1)
    expect(micStreams()[0].constraints).toEqual({ audio: true, video: false })
    expect(q("[data-lobby-meter]").hasAttribute("hidden")).toBe(false)

    preview.setAttribute("data-mic-enabled", "false")
    hook.updated()
    await flush()
    expect(micStreams()[0].track.stopped).toBe(true)
    expect(q("[data-lobby-meter]").hasAttribute("hidden")).toBe(true)
    expect(check().hasAttribute("hidden")).toBe(true)
    expect(contexts[0].closed).toBe(true)
    // The camera was never touched by the mic toggle.
    expect(camStreams()[0].track.stopped).toBe(false)
  })

  it("stops EVERY track it opened, camera and microphone, on destroyed", async () => {
    const { hook, video } = mountLobby()
    await flush()
    expect(gum).toHaveLength(2)

    hook.destroyed()
    for (const s of gum) expect(s.track.stopped).toBe(true)
    expect(video.srcObject).toBeNull()
    expect(contexts.every((c) => c.closed)).toBe(true)

    // Nothing ticks on after destroy.
    samples = "zero"
    await vi.advanceTimersByTimeAsync(10_000)
    expect(opened).toEqual([])
  })

  it("re-opens the mic on meeting:active-device for audioinput, and restarts the check", async () => {
    mountLobby()
    await flush()
    await selectDevice("audioinput", "bh-1", { room: null })
    await flush()

    expect(micStreams()[0].track.stopped).toBe(true)
    expect(micStreams().at(-1).constraints).toEqual({ audio: { deviceId: "bh-1" }, video: false })
    expect(label("audioinput")).toBe("BlackHole 2ch")
    expect(shownCopy()).toEqual(["invitation"])
  })

  // ── the mic check ─────────────────────────────────────────────────

  it("starts as the invitation once the mic is live", async () => {
    mountLobby()
    await flush()
    expect(check().hasAttribute("hidden")).toBe(false)
    expect(check().getAttribute("data-state")).toBe("invitation")
    expect(shownCopy()).toEqual(["invitation"])
  })

  it("does NOT warn before 5s of flat input after the invitation", async () => {
    mountLobby()
    await flush()
    await vi.advanceTimersByTimeAsync(FLAT_WARN_MS - 200)
    expect(check().getAttribute("data-state")).toBe("invitation")
    expect(opened).toEqual([])
  })

  it("warns at 5s of flat input, and expands MICROPHONE inline", async () => {
    mountLobby()
    await flush()
    await vi.advanceTimersByTimeAsync(FLAT_WARN_MS + 200)
    expect(check().getAttribute("data-state")).toBe("warning")
    expect(shownCopy()).toEqual(["warning"])
    const icons = check()
      .querySelectorAll("[data-mic-check-icon]")
      .filter((n) => !n.hasAttribute("hidden"))
    expect(icons.map((n) => n.getAttribute("data-mic-check-icon"))).toEqual(["warning"])
    expect(opened).toEqual([
      { id: "meeting-lobby-devices-panel", container: "inline", section: "audioinput" },
    ])
  })

  it("warns well before 5s on digital silence (every sample exactly zero)", async () => {
    samples = "zero"
    mountLobby()
    await flush()
    await vi.advanceTimersByTimeAsync(DIGITAL_SILENCE_MS + 200)
    expect(DIGITAL_SILENCE_MS + 200).toBeLessThan(FLAT_WARN_MS)
    expect(check().getAttribute("data-state")).toBe("warning")
    expect(opened).toHaveLength(1)
  })

  it("turns into 'We can hear you' on signal, then fades; no warning after", async () => {
    mountLobby()
    await flush()
    await vi.advanceTimersByTimeAsync(1000)
    samples = "loud"
    await vi.advanceTimersByTimeAsync(METER_MS * 2)
    expect(check().getAttribute("data-state")).toBe("heard")
    expect(shownCopy()).toEqual(["heard"])

    samples = "flat"
    await vi.advanceTimersByTimeAsync(HEARD_FADE_MS + 100)
    expect(check().getAttribute("data-faded")).toBe("true")
    await vi.advanceTimersByTimeAsync(1000)
    expect(check().hasAttribute("hidden")).toBe(true)
    await vi.advanceTimersByTimeAsync(FLAT_WARN_MS * 2)
    expect(check().getAttribute("data-state")).toBe("heard")
    expect(opened).toEqual([])
  })

  it("a warning turns into 'We can hear you' once there is sound", async () => {
    mountLobby()
    await flush()
    await vi.advanceTimersByTimeAsync(FLAT_WARN_MS + 200)
    expect(check().getAttribute("data-state")).toBe("warning")
    samples = "loud"
    await vi.advanceTimersByTimeAsync(METER_MS * 2)
    expect(check().getAttribute("data-state")).toBe("heard")
  })

  it("a SUSPENDED AudioContext (reads as silence) never warns", async () => {
    ctxState = "suspended"
    samples = "zero"
    mountLobby()
    await flush()
    await vi.advanceTimersByTimeAsync(FLAT_WARN_MS * 3)
    expect(check().getAttribute("data-state")).toBe("invitation")
    expect(opened).toEqual([])
  })

  it("paints the meter from the analyser", async () => {
    samples = "loud"
    mountLobby()
    await flush()
    await vi.advanceTimersByTimeAsync(METER_MS * 2)
    const bars = q("[data-lobby-meter]").querySelectorAll("[data-meter-bar]")
    expect(bars).toHaveLength(5)
    expect(bars.every((b) => /^scaleY\(/.test(b.style.transform))).toBe(true)
  })
})
