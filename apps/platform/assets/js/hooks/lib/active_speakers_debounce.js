/**
 * The `active_speakers` push guard shared by `MeetingRoom` (LiveKit's
 * `activeSpeakersChanged` in a browser) and `MeetingClient` (the
 * `SuiteMeetings` plugin's `activeSpeakers` listener inside the iOS app).
 *
 * Both sources fire many times a second, and an undebounced push is a
 * render storm on a LiveView that repaints the whole gallery. Two guards,
 * in order:
 *   1. Identity-set equality: an unchanged set is dropped outright.
 *   2. A 250 ms TRAILING timer: bursts of genuinely-changing sets collapse
 *      into a single flush carrying the LAST set seen.
 *
 * State lives on `holder` (the hook) as `_lastSpeakerKey`,
 * `_pendingSpeakers` and `_speakerTimer`, so a hook built with
 * `Object.create` and never mounted still works, and `destroyed()` can
 * clear the timer by name.
 */

// Trailing-debounce window, in ms.
export const ACTIVE_SPEAKER_DEBOUNCE_MS = 250

// Non-empty identity strings, sorted, so set equality is string equality.
export function normalizeIdentities(identities) {
  return (identities || []).filter((id) => typeof id === "string" && id !== "").sort()
}

// Offer a new identity list. `flush(identities)` runs at most once per
// window, and never for a set equal to the last one flushed.
export function offerActiveSpeakers(holder, identities, flush) {
  const sorted = normalizeIdentities(identities)
  const key = sorted.join("\u0000")

  // Guard 1: nothing changed since the last flush.
  if (key === holder._lastSpeakerKey) return

  // Guard 2: trailing debounce. Keep the newest payload and reset the timer
  // so a burst results in exactly one flush.
  holder._pendingSpeakers = sorted
  if (holder._speakerTimer) clearTimeout(holder._speakerTimer)
  holder._speakerTimer = setTimeout(() => {
    holder._speakerTimer = null
    const pending = holder._pendingSpeakers || []
    const pendingKey = pending.join("\u0000")
    if (pendingKey === holder._lastSpeakerKey) return
    holder._lastSpeakerKey = pendingKey
    flush(pending)
  }, ACTIVE_SPEAKER_DEBOUNCE_MS)
}

export function cancelActiveSpeakers(holder) {
  if (holder._speakerTimer) {
    clearTimeout(holder._speakerTimer)
    holder._speakerTimer = null
  }
}
