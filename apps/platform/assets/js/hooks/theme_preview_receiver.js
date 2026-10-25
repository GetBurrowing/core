/**
 * The theme editor's preview receiver (task 01a1557a-fe9b stage 2).
 *
 * /admin/themes frames the real app at /chat?theme_preview=1 and posts the
 * draft into each frame (./theme_editor.js). app.js installs this receiver
 * only in that case: the page is framed AND the URL carries theme_preview=1.
 * Anywhere else it never listens.
 *
 * A message is applied only when all of these hold:
 *   - event.origin === location.origin (the editor is this app, so its
 *     origin is ours; anything else is ignored);
 *   - event.source is the parent window, when a parent is known;
 *   - data.type === "burrow-theme" and data.mode is "dark" or "light".
 *
 * Then each var whose NAME is on ALLOWED_VARS and whose VALUE passes
 * `safeValue` is set with style.setProperty on <html>, and data-theme is set
 * to the mode. Nothing is persisted: no storage, no cookie, no server call. A
 * reload of the frame shows the person's own theme again until the editor
 * posts once more.
 *
 * ALLOWED_VARS is every name `Platform.Theming.Tokens.declarations/2` emits;
 * theme_preview_allowlist_parity_test.exs holds the two lists equal.
 */

export const MESSAGE_TYPE = "burrow-theme"

const AGENTS = ["teal", "green", "amber", "orange", "blue", "purple", "brick", "rose", "indigo", "lime"]

export const ALLOWED_VARS = new Set([
  "--color-base-100",
  "--color-base-200",
  "--color-base-300",
  "--edge",
  "--viewer",
  "--stage",
  "--color-base-content",
  "--color-secondary",
  "--color-secondary-content",
  "--color-primary",
  "--color-primary-content",
  "--color-accent",
  "--color-accent-content",
  "--color-interactive",
  "--focus-ring",
  "--color-info",
  "--color-info-content",
  "--info-dim",
  "--color-success",
  "--color-success-content",
  "--success-dim",
  "--color-warning",
  "--color-warning-content",
  "--warning-dim",
  "--color-error",
  "--color-error-content",
  ...AGENTS.flatMap((id) => [`--ag-${id}`, `--ag-${id}-text`]),
  "--subtle",
  "--disabled",
  "--decorative",
  "--ag-tint-pct",
  "--radius-box",
  "--radius-field",
  "--font-sans",
  "--density",
  "--glass-alpha",
  "--glass-blur",
])

const MODES = new Set(["dark", "light"])
const VALUE_CHARS = /^[A-Za-z0-9 #.,%()"'-]{1,160}$/
const ALLOWED_FUNCTIONS = new Set(["color-mix", "var"])

// A value the server could have produced: hex, lengths, numbers, font
// stacks, and color-mix()/var() only. No url(), no other function.
export function safeValue(value) {
  if (typeof value !== "string" || !VALUE_CHARS.test(value)) return false
  for (const match of value.matchAll(/([A-Za-z-]+)\s*\(/g)) {
    if (!ALLOWED_FUNCTIONS.has(match[1].toLowerCase())) return false
  }
  return true
}

// `[name, value]` pairs that may be applied; everything else is dropped.
export function sanitizeVars(vars) {
  if (!vars || typeof vars !== "object" || Array.isArray(vars)) return []
  return Object.entries(vars).filter(([name, value]) => ALLOWED_VARS.has(name) && safeValue(value))
}

// Applies one message event to `root`. Returns true when it was applied.
export function handleMessage(event, { origin, root, parent }) {
  if (!event || event.origin !== origin) return false
  if (parent && event.source !== parent) return false
  const data = event.data
  if (!data || data.type !== MESSAGE_TYPE || !MODES.has(data.mode)) return false

  for (const [name, value] of sanitizeVars(data.vars)) root.style.setProperty(name, value)
  root.setAttribute("data-theme", data.mode)
  return true
}

export function shouldInstall(win) {
  let framed
  try {
    framed = win.parent !== win
  } catch (_e) {
    framed = true
  }
  if (!framed) return false
  return new URLSearchParams(win.location.search).get("theme_preview") === "1"
}

export function installThemePreviewReceiver(win = window) {
  if (!shouldInstall(win)) return false
  const root = win.document.documentElement
  win.addEventListener("message", (event) =>
    handleMessage(event, { origin: win.location.origin, root, parent: win.parent }),
  )
  return true
}
