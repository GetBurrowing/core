// The terminal's fixed dark palette, the same in both themes (direction canvas
// 01a17b18-3989, DELIBERATE EXCEPTION to theme-following).
//
//   ground      the dark theme's base-100     #191b20
//   text/cursor the dark theme's base-content #eeeff1 (block cursor)
//   selection   the dark theme's base-300     #25272b
//
// The 16 ANSI colours start from xterm's defaults. Any that measures under 4.5:1
// against the ground is lifted (mixed toward white in 1% steps) until it passes;
// `LIFTED` names which changed. Measured here, asserted in test/terminal/palette.test.js.

export const GROUND = "#191b20"
export const FOREGROUND = "#eeeff1"
export const SELECTION = "#25272b"
export const MIN_CONTRAST = 4.5

export const XTERM_DEFAULT_ANSI = [
  "#2e3436", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b", "#06989a", "#d3d7cf",
  "#555753", "#ef2929", "#8ae234", "#fce94f", "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
]

const toRgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16))
const toHex = (rgb) => "#" + rgb.map((v) => Math.round(v).toString(16).padStart(2, "0")).join("")

export function luminance(hex) {
  const [r, g, b] = toRgb(hex).map((v) => {
    const c = v / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

/** Mix `hex` toward white until it reaches `min` against `ground`. */
export function lift(hex, ground = GROUND, min = MIN_CONTRAST) {
  if (contrast(hex, ground) >= min) return hex
  const rgb = toRgb(hex)
  for (let step = 1; step <= 100; step++) {
    const mixed = toHex(rgb.map((v) => v + (255 - v) * (step / 100)))
    if (contrast(mixed, ground) >= min) return mixed
  }
  return "#ffffff"
}

export const ANSI = XTERM_DEFAULT_ANSI.map((c) => lift(c))

/** Indexes whose colour was lifted. */
export const LIFTED = ANSI.flatMap((c, i) => (c === XTERM_DEFAULT_ANSI[i] ? [] : [i]))

const NAMES = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

/** xterm's theme object. */
export const THEME = {
  background: GROUND,
  foreground: FOREGROUND,
  cursor: FOREGROUND,
  cursorAccent: GROUND,
  selectionBackground: SELECTION,
  ...Object.fromEntries(ANSI.map((c, i) => [i < 8 ? NAMES[i] : "bright" + NAMES[i - 8][0].toUpperCase() + NAMES[i - 8].slice(1), c])),
}
