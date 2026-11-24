// On-device Voice (task 01a20dc5 stage 3): the one seam between the Voice
// tab and the iOS app's `BurrowVoice` plugin
// (clients/ios/ios/App/App/Plugins/BurrowVoicePlugin.swift).
//
// `onDeviceVoiceCapability()` is the single question "can this client talk
// on the device?". It answers `available: false` for a browser, Android, an
// older app build without the plugin (prod web is served to every installed
// build, and Capacitor rejects an unknown plugin or method), an iPhone whose
// SpeechTranscriber is unavailable, and on ANY throw or hang. The follow-up
// that shows Voice only on compatible iPhones calls this same function; this
// ticket hides Voice for nobody.

export const CAPABILITY_TIMEOUT_MS = 3000

const REASONS = [
  "os_too_old",
  "unavailable",
  "locale_unsupported",
  "speech_permission_denied",
  "assets_missing",
]

function capacitor(win) {
  const w = win || (typeof window !== "undefined" ? window : undefined)
  return w && w.Capacitor
}

// The `BurrowVoice` plugin inside the native app, or null.
export function nativeVoice(win) {
  const cap = capacitor(win)
  if (!cap || typeof cap.isNativePlatform !== "function") return null
  try {
    if (cap.isNativePlatform() !== true) return null
  } catch (_e) {
    return null
  }
  const plugin = cap.Plugins && cap.Plugins.BurrowVoice
  return plugin && typeof plugin.capabilities === "function" ? plugin : null
}

function timeout(promise, ms) {
  let timer
  const late = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error("capability timeout")), ms)
  })
  return Promise.race([promise, late]).finally(() => clearTimeout(timer))
}

// The plugin's `capabilities()` payload as {available, reason, locale,
// testBuild, micPermission, plugin}. `plugin` is set whenever the plugin
// answered (also when unavailable), so `assets_missing` can call prepare().
export function capabilityOf(caps, plugin) {
  if (!caps || typeof caps !== "object") return { available: false, reason: "unknown", plugin }
  const reason = REASONS.includes(caps.reason) ? caps.reason : caps.onDeviceSpeech === true ? null : "unknown"
  return {
    available: caps.onDeviceSpeech === true,
    reason,
    locale: typeof caps.locale === "string" ? caps.locale : null,
    testBuild: caps.testBuild === true,
    micPermission: typeof caps.micPermission === "string" ? caps.micPermission : null,
    plugin,
  }
}

export async function onDeviceVoiceCapability(win, ms = CAPABILITY_TIMEOUT_MS) {
  try {
    const plugin = nativeVoice(win)
    if (!plugin) return { available: false, reason: "no_plugin", plugin: null }
    return capabilityOf(await timeout(Promise.resolve(plugin.capabilities()), ms), plugin)
  } catch (_e) {
    return { available: false, reason: "error", plugin: null }
  }
}
