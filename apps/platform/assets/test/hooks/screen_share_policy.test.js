import { describe, expect, it, vi } from "vitest"
import {
  browserSupportsH264ScreenShare,
  captureOptionsForProfile,
  publishOptionsForSettings,
  screenSharePolicyReport,
  toggleScreenShare,
} from "../../js/hooks/lib/screen_share_policy.js"

function videoTrack(settings = { width: 1920, height: 1080, frameRate: 60 }) {
  return {
    kind: "video",
    source: "screen_share",
    mediaStreamTrack: { getSettings: () => settings },
    stop: vi.fn(),
  }
}

function windowsH264Env() {
  return {
    navigator: { userAgent: "Mozilla/5.0 (Windows NT 10.0) AppleWebKit Chrome/130.0" },
    RTCRtpSender: {
      getCapabilities: () => ({ codecs: [{ mimeType: "video/VP8" }, { mimeType: "video/H264" }] }),
    },
  }
}

describe("adaptive screen-share policy", () => {
  it("offers explicit maximum, smooth, compatible, and detail capture profiles", () => {
    expect(captureOptionsForProfile("maximum")).toEqual({
      audio: true,
      resolution: { width: 3840, height: 2160, frameRate: 120 },
      contentHint: "motion",
    })
    expect(captureOptionsForProfile("smooth").resolution.frameRate).toBe(60)
    expect(captureOptionsForProfile("compatible").resolution.frameRate).toBe(30)
    expect(captureOptionsForProfile("detail").contentHint).toBe("detail")
  })

  it("derives bitrate and simulcast from actual capture settings", () => {
    const options = publishOptionsForSettings(
      { width: 2560, height: 1440, frameRate: 72 },
      { codec: "h264" },
    )

    expect(options.videoCodec).toBe("h264")
    expect(options.degradationPreference).toBe("maintain-framerate")
    expect(options.screenShareEncoding.maxFramerate).toBe(72)
    expect(options.screenShareEncoding.maxBitrate).toBe(21_233_664)
    expect(options.screenShareSimulcastLayers).toHaveLength(2)
    expect(options.screenShareSimulcastLayers[1]).toEqual(
      expect.objectContaining({
        width: 1280,
        height: 720,
        encoding: expect.objectContaining({ maxFramerate: 30 }),
      }),
    )
  })

  it("reports requested ceiling separately from truthful captured settings", () => {
    const captureOptions = captureOptionsForProfile("maximum")
    const settings = { width: 1920, height: 1080, frameRate: 59.94 }
    const publishOptions = publishOptionsForSettings(settings)
    const report = screenSharePolicyReport({
      profile: "maximum",
      captureOptions,
      settings,
      publishOptions,
      fallbackUsed: false,
    })

    expect(report.requested.frameRateCeiling).toBe(120)
    expect(report.captured.frameRate).toBe(59.94)
    expect(report.published.maxFramerate).toBe(59.94)
    expect(report).not.toHaveProperty("negotiatedFrameRate")
  })

  it("prefers H.264 only on capable Windows Chromium", () => {
    expect(browserSupportsH264ScreenShare(windowsH264Env())).toBe(true)
    expect(
      browserSupportsH264ScreenShare({
        ...windowsH264Env(),
        navigator: { userAgent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/130.0" },
      }),
    ).toBe(false)
  })

  it("falls back cleanly from H.264 to VP8 without recapturing", async () => {
    const video = videoTrack()
    const audio = { kind: "audio", source: "screen_share_audio", stop: vi.fn() }
    const publishTrack = vi
      .fn()
      .mockRejectedValueOnce(new Error("H.264 encoder unavailable"))
      .mockResolvedValue({})
    const participant = {
      isScreenShareEnabled: false,
      createScreenTracks: vi.fn().mockResolvedValue([video, audio]),
      publishTrack,
      unpublishTrack: vi.fn().mockResolvedValue(undefined),
    }
    const reports = []

    await toggleScreenShare(
      { localParticipant: participant },
      { env: windowsH264Env(), onPolicy: (report) => reports.push(report) },
    )

    expect(participant.createScreenTracks).toHaveBeenCalledTimes(1)
    expect(publishTrack.mock.calls[0][1].videoCodec).toBe("h264")
    expect(publishTrack.mock.calls[1][1].videoCodec).toBe("vp8")
    expect(publishTrack.mock.calls[2]).toEqual([audio])
    expect(participant.unpublishTrack).toHaveBeenCalledWith(video, false)
    expect(reports[0]).toMatchObject({ fallbackUsed: true, published: { codec: "vp8" } })
  })

  it("deduplicates concurrent toggles while preserving synchronous capture", async () => {
    let resolveCapture
    const capture = new Promise((resolve) => {
      resolveCapture = resolve
    })
    const participant = {
      isScreenShareEnabled: false,
      createScreenTracks: vi.fn(() => capture),
      publishTrack: vi.fn().mockResolvedValue({}),
    }
    const room = { localParticipant: participant }

    const first = toggleScreenShare(room, { env: {} })
    const duplicate = toggleScreenShare(room, { env: {} })

    expect(participant.createScreenTracks).toHaveBeenCalledTimes(1)
    expect(first).toBe(duplicate)

    resolveCapture([videoTrack()])
    await Promise.all([first, duplicate])
    expect(participant.publishTrack).toHaveBeenCalledTimes(1)
  })

  it("routes disable through the parameterized LiveKit toggle", async () => {
    const participant = {
      isScreenShareEnabled: true,
      setScreenShareEnabled: vi.fn().mockResolvedValue(undefined),
    }

    await toggleScreenShare({ localParticipant: participant })

    expect(participant.setScreenShareEnabled).toHaveBeenCalledWith(
      false,
      expect.objectContaining({ audio: true, resolution: expect.objectContaining({ frameRate: 120 }) }),
      expect.objectContaining({ degradationPreference: "maintain-framerate" }),
    )
  })
})
