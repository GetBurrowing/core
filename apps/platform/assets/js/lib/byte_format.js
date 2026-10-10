// Byte labels for people (task 01a120be): ONE decimal rule on every surface
// (server `Platform.Chat.UploadLimits`, web, Android, iOS), so a size never
// reads in two different units on one screen.
//
//   formatBytes(bytes):
//     bytes < 1000 -> "<bytes> bytes"
//     otherwise the largest k in {1: KB, 2: MB, 3: GB, 4: TB} with
//     bytes >= 1000^k; v = bytes / 1000^k rounded half-up to one decimal;
//     if v >= 1000 and k < 4, step up one unit and recompute;
//     no trailing ".0".
//
//   formatProgress(sent, total): the unit is picked from `total`, and `sent`
//     (clamped to total) is rendered in that same unit:
//     "<sent> of <total> <unit>".

const UNITS = ["bytes", "KB", "MB", "GB", "TB"]

// Rounded to one decimal, half-up, computed on integers so 1.05 does not
// become 1.0 through binary floating point.
function tenths(bytes, k) {
  const div = 1000 ** k
  return Math.floor((bytes * 10) / div + 0.5) / 10
}

function unitFor(bytes) {
  if (!(bytes >= 1000)) return 0
  let k = 1
  while (k < 4 && bytes >= 1000 ** (k + 1)) k += 1
  if (tenths(bytes, k) >= 1000 && k < 4) k += 1
  return k
}

function render(v) {
  return Number.isInteger(v) ? String(v) : v.toFixed(1)
}

function clean(n) {
  const v = Math.floor(Number(n))
  return Number.isFinite(v) && v > 0 ? v : 0
}

export function formatBytes(bytes) {
  const b = clean(bytes)
  const k = unitFor(b)
  if (k === 0) return `${b} bytes`
  return `${render(tenths(b, k))} ${UNITS[k]}`
}

export function formatProgress(sent, total) {
  const t = clean(total)
  const s = Math.min(clean(sent), t)
  const k = unitFor(t)
  if (k === 0) return `${s} of ${t} bytes`
  return `${render(tenths(s, k))} of ${render(tenths(t, k))} ${UNITS[k]}`
}

// " · about 2 min" / " · about 40 s" / "" — appended to a progress line.
export function formatEta(seconds) {
  const s = Number(seconds)
  if (!Number.isFinite(s) || s <= 0) return ""
  if (s >= 90) return ` · about ${Math.round(s / 60)} min`
  return ` · about ${Math.max(1, Math.round(s))} s`
}
