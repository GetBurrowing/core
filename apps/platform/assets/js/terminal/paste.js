// Multi-line paste guard. Acts in the browser on the user's own clipboard text
// BEFORE anything is sent; it never looks at what the terminal prints.

/** Number of lines in pasted text: a trailing line break ends a line, it does not start one. */
export function countLines(text) {
  if (typeof text !== "string" || text === "") return 0
  const parts = text.split(/\r\n|\r|\n/)
  if (parts[parts.length - 1] === "") parts.pop()
  return parts.length
}

/** More than one line runs more than one command, so it asks first. */
export const needsConfirm = (text) => countLines(text) > 1

export const confirmText = (text) => `Paste ${countLines(text)} lines into your terminal?`
