/**
 * Shared RMS waveform-bar math (task 01a0cf5c stage 2).
 *
 * `meeting_push_to_talk.js` pairs this with its own live `AnalyserNode`
 * reading the local mic track and paints the small waveform on the
 * per-agent hold button with it. `meeting_ask_floor_veil.js` needs the
 * IDENTICAL bar shape for the meter inside the new centred "asking" card
 * — the design-direction canvas (01a0cf5e-9cb0) is explicit that this
 * meter must read as a LIVE LEVEL, not a duration-filling progress bar,
 * and the one thing already proven to read that way is this exact
 * formula. Rather than open a second `AnalyserNode` on the same track
 * (the button hook already owns the only one, and a track can be tapped
 * more than once but there is no reason to), the veil hook reuses this
 * pure function against the SAME measured `level` the button hook
 * broadcasts on every sample via the `meeting:push-to-talk-level` window
 * event. One measurement, two renderers, same math.
 */

/** The per-bar scale factor for one sample, shaped so the bars read as a
 * waveform (taller near the centre) rather than a single flat block. */
export function barScale(level, index, count) {
  const distance = Math.abs(index - (count - 1) / 2) / ((count - 1) / 2 || 1)
  const weight = 1 - distance * 0.55
  return Math.max(0.08, Math.min(1, level * weight * 2.2))
}

/** Paint every bar element's `scaleY` transform for one measured level. */
export function paintBars(bars, level) {
  if (!bars || bars.length === 0) return

  const count = bars.length

  for (let i = 0; i < count; i++) {
    const scaled = barScale(level, i, count)
    bars[i].style.transform = `scaleY(${scaled.toFixed(3)})`
  }
}
