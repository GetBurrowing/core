// The phone key row. Phone keyboards have no Esc, Tab, Ctrl or arrows, and
// Claude Code needs all of them. Ctrl is sticky: it applies to the NEXT key only.

export const KEY_BYTES = {
  esc: "\x1b",
  tab: "\t",
  up: "\x1b[A",
  down: "\x1b[B",
  right: "\x1b[C",
  left: "\x1b[D",
}

/** Control-modified form of one typed character, or the character unchanged. */
export function applyCtrl(text) {
  if (typeof text !== "string" || text.length !== 1) return text
  const code = text.toUpperCase().charCodeAt(0)
  if (code >= 0x40 && code <= 0x5f) return String.fromCharCode(code - 0x40)
  return text
}
