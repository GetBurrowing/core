import { describe, expect, it, vi } from "vitest"
import { AudioPlayback, routeInboundTrack } from "../js/hooks/lib/game_stream_audio.js"

class FakeMediaStream {
  constructor(tracks) {
    this.tracks = tracks
  }
}

function track(kind, id = kind) {
  const listeners = new Map()
  return {
    kind,
    id,
    addEventListener(type, fn) {
      listeners.set(type, fn)
    },
    removeEventListener(type, fn) {
      if (listeners.get(type) === fn) listeners.delete(type)
    },
    listenerCount(type) {
      return listeners.has(type) ? 1 : 0
    },
    end() {
      if (listeners.has("ended")) listeners.get("ended")()
    },
  }
}

function fixture(play = vi.fn(() => Promise.resolve())) {
  const element = { srcObject: null, muted: false, play, pause: vi.fn() }
  const stateElement = { textContent: "", dataset: {} }
  const attrs = {}
  const button = {
    disabled: false,
    textContent: "",
    setAttribute(name, value) {
      attrs[name] = value
    },
  }
  const audio = new AudioPlayback({
    element,
    stateElement,
    button,
    MediaStreamCtor: FakeMediaStream,
  })
  return { audio, element, stateElement, button, attrs }
}

const flush = () => new Promise(resolve => setTimeout(resolve, 0))

describe("game_stream inbound track routing", () => {
  it("keeps video on muted video and audio on a dedicated audio-only stream", () => {
    const video = {
      muted: false,
      srcObject: null,
      removeAttribute: vi.fn(),
      play: vi.fn(() => Promise.resolve()),
    }
    const audio = fixture().audio
    const videoTrack = track("video")
    const audioTrack = track("audio")
    const mixedRemoteStream = { tracks: [videoTrack, audioTrack] }
    const onVideo = vi.fn()

    expect(
      routeInboundTrack(
        { track: videoTrack, streams: [mixedRemoteStream] },
        { video, audio, onVideo, MediaStreamCtor: FakeMediaStream },
      ),
    ).toBe("video")
    expect(video.srcObject).toBe(mixedRemoteStream)
    expect(video.muted).toBe(true)
    expect(onVideo).toHaveBeenCalledOnce()

    expect(
      routeInboundTrack(
        { track: audioTrack, streams: [mixedRemoteStream] },
        { video, audio, onVideo, MediaStreamCtor: FakeMediaStream },
      ),
    ).toBe("audio")
    expect(audio.element.srcObject.tracks).toEqual([audioTrack])
    expect(video.srcObject).toBe(mixedRemoteStream)
    expect(onVideo).toHaveBeenCalledOnce()
  })
})

describe("AudioPlayback autoplay and truthful state", () => {
  it("waits when audio arrives before a gesture, then plays from the gesture", async () => {
    const { audio, element, stateElement } = fixture()
    audio.attach(track("audio"))
    expect(element.play).not.toHaveBeenCalled()
    expect(stateElement.dataset.gsAudioState).toBe("waiting")

    await audio.gesture()
    expect(element.play).toHaveBeenCalledOnce()
    expect(stateElement.dataset.gsAudioState).toBe("playing")
  })

  it("plays immediately when the track arrives after the existing play gesture", async () => {
    const { audio, element, stateElement } = fixture()
    await audio.gesture()
    audio.attach(track("audio"))
    await flush()
    expect(element.play).toHaveBeenCalledOnce()
    expect(stateElement.dataset.gsAudioState).toBe("playing")
  })

  it("reports autoplay rejection as blocked and retries on the next gesture", async () => {
    const denied = Object.assign(new Error("gesture required"), { name: "NotAllowedError" })
    const play = vi.fn().mockRejectedValueOnce(denied).mockResolvedValueOnce()
    const { audio, stateElement, button } = fixture(play)
    audio.attach(track("audio"))

    await audio.gesture()
    expect(stateElement.dataset.gsAudioState).toBe("blocked")
    expect(button.textContent).toBe("Play sound")

    await audio.action()
    expect(play).toHaveBeenCalledTimes(2)
    expect(stateElement.dataset.gsAudioState).toBe("playing")
  })

  // Every forwarded touch (and every tap on the well) calls gesture(). While
  // audio is already playing, that must not re-enter "waiting": the label
  // flipped to "Waiting for audio" and back on every tap, and its width
  // change slid the Mute button (Alex's playtest, 2026-10-02).
  it("a gesture while already playing renders nothing new and does not replay", async () => {
    const element = { srcObject: null, muted: false, paused: true, pause: vi.fn() }
    element.play = vi.fn(() => {
      element.paused = false
      return Promise.resolve()
    })
    const seen = []
    const dataset = {}
    let current
    Object.defineProperty(dataset, "gsAudioState", {
      get: () => current,
      set: v => {
        current = v
        seen.push(v)
      },
    })
    const audio = new AudioPlayback({
      element,
      stateElement: { textContent: "", dataset },
      button: null,
      MediaStreamCtor: FakeMediaStream,
    })
    audio.attach(track("audio"))
    await audio.gesture()
    expect(current).toBe("playing")
    seen.length = 0

    for (let i = 0; i < 3; i++) await audio.gesture()
    expect(seen).toEqual([])
    expect(element.play).toHaveBeenCalledOnce()

    // Paused underneath (an OS interruption): the next gesture plays again.
    element.paused = true
    await audio.gesture()
    expect(element.play).toHaveBeenCalledTimes(2)
    expect(current).toBe("playing")
  })

  it("reports non-policy playback failures as errors, never playing", async () => {
    const { audio, stateElement } = fixture(vi.fn(() => Promise.reject(new Error("decoder"))))
    audio.attach(track("audio"))
    await audio.gesture()
    expect(stateElement.dataset.gsAudioState).toBe("error")
  })
})

describe("AudioPlayback mute and reconnect", () => {
  it("mutes and unmutes locally exactly once without any peer operation", async () => {
    const { audio, element, stateElement } = fixture()
    const peer = { createOffer: vi.fn(), setLocalDescription: vi.fn() }
    audio.attach(track("audio"))
    await audio.gesture()

    expect(audio.toggleMute()).toBe(true)
    expect(element.muted).toBe(true)
    expect(stateElement.dataset.gsAudioState).toBe("muted")
    expect(audio.toggleMute()).toBe(false)
    await flush()
    expect(element.muted).toBe(false)
    expect(stateElement.dataset.gsAudioState).toBe("playing")
    expect(peer.createOffer).not.toHaveBeenCalled()
    expect(peer.setLocalDescription).not.toHaveBeenCalled()
  })

  it("removes the old ended listener and stream before a reconnect track", async () => {
    const { audio, element, stateElement } = fixture()
    const first = track("audio", "first")
    const second = track("audio", "second")
    await audio.gesture()
    audio.attach(first)
    await flush()
    expect(first.listenerCount("ended")).toBe(1)

    audio.attach(second)
    await flush()
    expect(first.listenerCount("ended")).toBe(0)
    expect(second.listenerCount("ended")).toBe(1)
    expect(element.srcObject.tracks).toEqual([second])
    expect(stateElement.dataset.gsAudioState).toBe("playing")

    audio.detach()
    expect(second.listenerCount("ended")).toBe(0)
    expect(element.srcObject).toBe(null)
    expect(stateElement.dataset.gsAudioState).toBe("waiting")
  })
})
