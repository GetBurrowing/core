// One policy for every meeting screen-share entry point. Capture is performed
// before publication so the encoding ladder is based on what the browser
// actually granted, not on the 120 fps request ceiling.

export const SCREEN_SHARE_PROFILES = Object.freeze({
  maximum: Object.freeze({ width: 3840, height: 2160, frameRate: 120, contentHint: "motion" }),
  smooth: Object.freeze({ width: 1920, height: 1080, frameRate: 60, contentHint: "motion" }),
  compatible: Object.freeze({ width: 1920, height: 1080, frameRate: 30, contentHint: "motion" }),
  detail: Object.freeze({ width: 3840, height: 2160, frameRate: 30, contentHint: "detail" }),
})

const inFlightToggles = new WeakMap()

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

export function captureOptionsForProfile(profile = "maximum") {
  const selected = SCREEN_SHARE_PROFILES[profile] || SCREEN_SHARE_PROFILES.maximum
  return {
    audio: true,
    resolution: {
      width: selected.width,
      height: selected.height,
      frameRate: selected.frameRate,
    },
    contentHint: selected.contentHint,
  }
}

export function browserSupportsH264ScreenShare(env = globalThis) {
  const ua = env.navigator?.userAgent || ""
  const isWindowsChromium = /Windows/i.test(ua) && /(Chrome|Chromium|Edg)\//i.test(ua)
  if (!isWindowsChromium) return false

  const codecs = env.RTCRtpSender?.getCapabilities?.("video")?.codecs || []
  return codecs.some((codec) => codec.mimeType?.toLowerCase() === "video/h264")
}

export function trackSettings(track) {
  const settings = track?.mediaStreamTrack?.getSettings?.() || {}
  return {
    width: Number(settings.width) || 1920,
    height: Number(settings.height) || 1080,
    frameRate: Number(settings.frameRate) || 30,
  }
}

export function publishOptionsForSettings(settings, { codec = "vp8" } = {}) {
  const width = clamp(Number(settings?.width) || 1920, 320, 7680)
  const height = clamp(Number(settings?.height) || 1080, 180, 4320)
  const frameRate = clamp(Number(settings?.frameRate) || 30, 1, 120)
  // Bits-per-pixel is intentionally bounded: enough headroom for game motion,
  // while avoiding an impossible nominal rate for 4K/120 capture.
  const maxBitrate = Math.round(clamp(width * height * frameRate * 0.08, 2_500_000, 30_000_000))
  const layers = []

  if (width > 640 || height > 360) {
    layers.push({
      width: 640,
      height: 360,
      encoding: { maxBitrate: 700_000, maxFramerate: Math.min(15, frameRate), priority: "medium" },
    })
  }
  if (width > 1280 || height > 720) {
    layers.push({
      width: 1280,
      height: 720,
      encoding: { maxBitrate: 2_500_000, maxFramerate: Math.min(30, frameRate), priority: "medium" },
    })
  }

  return {
    videoCodec: codec,
    degradationPreference: "maintain-framerate",
    screenShareEncoding: {
      maxBitrate,
      maxFramerate: frameRate,
      priority: "high",
    },
    simulcast: layers.length > 0,
    screenShareSimulcastLayers: layers,
  }
}

export function screenSharePolicyReport({ profile, captureOptions, settings, publishOptions, fallbackUsed }) {
  return {
    profile,
    requested: {
      width: captureOptions.resolution.width,
      height: captureOptions.resolution.height,
      frameRateCeiling: captureOptions.resolution.frameRate,
    },
    // These are capture settings reported by the selected MediaStreamTrack.
    // They are deliberately not described as negotiated/sent frame rate.
    captured: { ...settings },
    published: {
      codec: publishOptions.videoCodec,
      maxBitrate: publishOptions.screenShareEncoding.maxBitrate,
      maxFramerate: publishOptions.screenShareEncoding.maxFramerate,
      simulcastLayers: publishOptions.screenShareSimulcastLayers.length,
    },
    fallbackUsed,
  }
}

function notifyPolicy(report, onPolicy) {
  if (onPolicy) onPolicy(report)
  if (typeof window !== "undefined" && typeof window.dispatchEvent === "function" && typeof CustomEvent === "function") {
    window.dispatchEvent(new CustomEvent("livekit:screen-share-policy", { detail: report }))
  }
}

async function cleanFailedPublication(participant, track) {
  try {
    await participant.unpublishTrack?.(track, false)
  } catch (_err) {
    // A failed publish normally has no publication to remove.
  }
}

async function enableScreenShare(participant, { profile, env, onPolicy }) {
  const captureOptions = captureOptionsForProfile(profile)
  // Calling createScreenTracks before the first await preserves direct-click
  // user activation for getDisplayMedia().
  const tracksPromise = participant.createScreenTracks(captureOptions)
  const tracks = await tracksPromise
  const videoTrack = tracks.find((track) => track.source === "screen_share" || track.kind === "video")
  const audioTracks = tracks.filter((track) => track !== videoTrack)
  if (!videoTrack) throw new Error("Screen capture returned no video track")

  const actualSettings = trackSettings(videoTrack)
  const preferredCodec = browserSupportsH264ScreenShare(env) ? "h264" : "vp8"
  let publishOptions = publishOptionsForSettings(actualSettings, { codec: preferredCodec })
  let fallbackUsed = false

  try {
    await participant.publishTrack(videoTrack, publishOptions)
  } catch (error) {
    if (preferredCodec !== "h264") {
      tracks.forEach((track) => track.stop?.())
      throw error
    }

    await cleanFailedPublication(participant, videoTrack)
    publishOptions = publishOptionsForSettings(actualSettings, { codec: "vp8" })
    fallbackUsed = true
    try {
      await participant.publishTrack(videoTrack, publishOptions)
    } catch (fallbackError) {
      tracks.forEach((track) => track.stop?.())
      throw fallbackError
    }
  }

  try {
    for (const audioTrack of audioTracks) await participant.publishTrack(audioTrack)
  } catch (error) {
    await cleanFailedPublication(participant, videoTrack)
    tracks.forEach((track) => track.stop?.())
    throw error
  }

  const report = screenSharePolicyReport({
    profile,
    captureOptions,
    settings: actualSettings,
    publishOptions,
    fallbackUsed,
  })
  notifyPolicy(report, onPolicy)
  return report
}

async function performToggle(room, options) {
  const participant = room?.localParticipant
  if (!participant) return undefined
  const profile = options.profile || "maximum"

  if (participant.isScreenShareEnabled) {
    // Supply the same policy arguments even though LiveKit ignores them while
    // disabling; no toggle path is left to inherit SDK defaults on refactors.
    const capture = captureOptionsForProfile(profile)
    const publish = publishOptionsForSettings(capture.resolution)
    return participant.setScreenShareEnabled(false, capture, publish)
  }

  return enableScreenShare(participant, { ...options, profile })
}

export function toggleScreenShare(room, options = {}) {
  const participant = room?.localParticipant
  if (!participant) return Promise.resolve(undefined)

  const pending = inFlightToggles.get(participant)
  if (pending) return pending

  const promise = performToggle(room, { env: globalThis, ...options })
  inFlightToggles.set(participant, promise)
  const clear = () => {
    if (inFlightToggles.get(participant) === promise) inFlightToggles.delete(participant)
  }
  promise.then(clear, clear)
  return promise
}
