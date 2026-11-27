// Constants and helpers shared by the Voice tab hook (voice_tab.js, in
// app.js) and its on-device half (voice_tab_native_runtime.js, in the
// voice_native island). Both bundles carry their own copy; nothing here is
// compared by identity across the two.

export const HOLD_MS = 280
export const CAPTION_EVENT = "voice:caption"
export const MIC_TIMEOUT_MS = 10000
export const TIMED_OUT = Symbol("timed out")
export const TURN_WARN_MS = 50000
export const TURN_CAP_MS = 60000
export const NO_WORDS_MS = 2000
// How far a held pointer may travel vertically from where it went down
// before the turn counts as a drag and is cancelled (deviation D3).
export const DRAG_CANCEL_PX = 24
// stop() finalises the transcript; give it longer than a start.
export const STOP_TIMEOUT_MS = 15000
export const RESTORE_MS = 3000

export function now() {
  return typeof performance !== "undefined" && performance.now ? performance.now() : Date.now()
}

export function localClock() {
  try {
    return new Date()
      .toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
      .replace(/\s+/gu, " ")
  } catch (_e) {
    return null
  }
}

// Settles with the promise, or with TIMED_OUT after `ms`, whichever is first.
export function withTimeout(promise, ms) {
  let timer
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve(TIMED_OUT), ms)
  })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

export function newTurnId() {
  try {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
      return crypto.randomUUID()
    }
  } catch (_e) {
    // fall through
  }
  return `t-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
}
