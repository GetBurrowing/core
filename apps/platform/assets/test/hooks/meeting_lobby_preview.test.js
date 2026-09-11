import { describe, it, expect, beforeEach, afterEach } from "vitest"
import MeetingLobbyPreview from "../../js/hooks/meeting_lobby_preview.js"

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
})
