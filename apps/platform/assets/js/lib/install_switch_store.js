/**
 * The web install switcher's model (task 01a1ccd4 stage 3): the install list
 * this browser holds, the unread fetch to each other install, and the rules
 * that turn answers into a dot. No DOM here; `hooks/install_switch_web.js`
 * draws it.
 *
 * The list lives in localStorage under `burrow.installs.v1` on each origin,
 * the browser analogue of the native app's device-held InstallStore: no
 * install's server learns which other installs a user belongs to.
 *
 * Unread comes from each other install's `GET /api/switcher/unread` (stage 2)
 * with that install's badge key in the Authorization header. Never a cookie
 * (`credentials: "omit"`), never a referrer, never a redirect followed.
 *
 * Rules, the native reconciler's:
 *   - at most 4 fetches in flight, each cut at 5 s;
 *   - the body must be exactly an integer `unread` and an ISO `as_of`, and a
 *     newer `as_of` wins over an older one;
 *   - a failure (network, timeout, 5xx) keeps the last count and marks the
 *     row stale; with no count known it is "unreachable";
 *   - 401 means the key was revoked or expired: "reconnect", count hidden;
 *   - any other refusal or a malformed body clears the count, so that row
 *     never lights the dot. A stale "on" is worse than a missed one.
 */

export const STORAGE_KEY = "burrow.installs.v1"
export const PENDING_KEY = "burrow.installs.pending.v1"
export const TOAST_KEY = "burrow.installs.toast.v1"
export const FETCH_TIMEOUT_MS = 5000
export const MAX_IN_FLIGHT = 4
export const REFRESH_MS = 60000
export const FIND_AT = 8
export const PENDING_TTL_MS = 30 * 60 * 1000
// The largest unread body read (stage 4). A real answer is ~60 bytes; a
// bigger one is refused without being read to the end.
export const MAX_BODY_BYTES = 4096

const MAX_ENTRIES = 50
const MAX_NAME = 120
const HOST_LABEL = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/
const BADGE_KEY = /^bk_[A-Za-z0-9_-]{20,200}$/
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/

const localHost = host =>
  host === "localhost" || host === "127.0.0.1" || host.endsWith(".localhost")

/**
 * The stage-2 origin rule, mirrored from `Platform.Switcher.normalize_origin/1`:
 * `https` on any host, `http` only on localhost, `*.localhost` and 127.0.0.1.
 * Returns the origin when `value` IS exactly an origin, else null (a path, a
 * query, a fragment, userinfo, whitespace or a backslash all refuse).
 */
export function allowedOrigin(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 300) return null
  if (/[\s\x00-\x1f\x7f\\]/.test(value)) return null
  let url
  try {
    url = new URL(value)
  } catch {
    return null
  }
  const scheme = url.protocol.slice(0, -1)
  if (scheme !== "https" && scheme !== "http") return null
  if (url.username || url.password) return null
  const host = url.hostname
  if (!host || !host.split(".").every(label => HOST_LABEL.test(label))) return null
  if (scheme === "http" && !localHost(host)) return null
  return url.origin === value ? value : null
}

/** What a person typed in "Add an install", as an origin, or null. */
export function originFromInput(text) {
  if (typeof text !== "string") return null
  const trimmed = text.trim()
  if (!trimmed || /[\s\\]/.test(trimmed)) return null
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : "https://" + trimmed
  let url
  try {
    url = new URL(withScheme)
  } catch {
    return null
  }
  if (url.username || url.password) return null
  return allowedOrigin(url.origin)
}

export function validIso(value) {
  return typeof value === "string" && ISO.test(value) && !Number.isNaN(Date.parse(value))
}

export function validBadgeKey(value) {
  return typeof value === "string" && BADGE_KEY.test(value)
}

export function hostOf(origin) {
  return new URL(origin).host
}

function cleanName(value, fallback) {
  if (typeof value !== "string") return fallback
  const name = value.replace(/[\x00-\x1f\x7f]/g, "").trim().slice(0, MAX_NAME)
  return name || fallback
}

/**
 * One stored entry, validated, or null. An entry whose origin fails the
 * origin rule is dropped. `host` is always derived from the origin, never
 * trusted from storage, so a row cannot claim to be somewhere else.
 */
export function validEntry(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  const origin = allowedOrigin(raw.origin)
  if (!origin) return null
  const host = hostOf(origin)
  return {
    origin,
    name: cleanName(raw.name, host),
    host,
    key: validBadgeKey(raw.key) ? raw.key : null,
    added_at: validIso(raw.added_at) ? raw.added_at : null,
    unread: Number.isInteger(raw.unread) && raw.unread >= 0 ? raw.unread : null,
    as_of: validIso(raw.as_of) ? raw.as_of : null
  }
}

/** The stored list, every entry validated, deduplicated by origin. */
export function readList(storage) {
  let raw
  try {
    raw = JSON.parse(storage?.getItem(STORAGE_KEY) ?? "[]")
  } catch {
    return []
  }
  if (!Array.isArray(raw)) return []
  const seen = new Set()
  const out = []
  for (const item of raw) {
    const entry = validEntry(item)
    if (!entry || seen.has(entry.origin)) continue
    seen.add(entry.origin)
    out.push(entry)
    if (out.length >= MAX_ENTRIES) break
  }
  return out
}

export function writeList(storage, list) {
  try {
    storage?.setItem(STORAGE_KEY, JSON.stringify(list.slice(0, MAX_ENTRIES)))
    return true
  } catch {
    return false
  }
}

/** Add or replace the entry for `entry.origin`; keeps its first `added_at`. */
export function upsertEntry(storage, entry) {
  const clean = validEntry(entry)
  if (!clean) return null
  const list = readList(storage)
  const i = list.findIndex(e => e.origin === clean.origin)
  if (i === -1) list.push(clean)
  else list[i] = { ...clean, added_at: list[i].added_at || clean.added_at }
  writeList(storage, list)
  return clean
}

export function removeEntry(storage, origin) {
  const list = readList(storage)
  const removed = list.find(e => e.origin === origin) || null
  writeList(
    storage,
    list.filter(e => e.origin !== origin)
  )
  return removed
}

/** Merge fields into the stored entry for `origin` (if it is still there). */
export function patchEntry(storage, origin, fields) {
  const list = readList(storage)
  const i = list.findIndex(e => e.origin === origin)
  if (i === -1) return null
  list[i] = { ...list[i], ...fields }
  writeList(storage, list)
  return list[i]
}

/**
 * The unread body, strictly: an object with EXACTLY two keys, `unread` a
 * non-negative integer and `as_of` an ISO-8601 timestamp. Anything else,
 * extra fields included (stage 4: a hostile install padding its answer), is
 * null and never lights the dot.
 */
export function parseUnread(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null
  const keys = Object.keys(body)
  if (keys.length !== 2 || !keys.includes("unread") || !keys.includes("as_of")) return null
  const { unread, as_of } = body
  if (!Number.isInteger(unread) || unread < 0) return null
  if (!validIso(as_of)) return null
  return { unread, as_of }
}

/** The options every unread fetch carries. Exported so tests can pin them. */
export function unreadRequest(key, signal) {
  return {
    method: "GET",
    mode: "cors",
    credentials: "omit",
    referrerPolicy: "no-referrer",
    cache: "no-store",
    redirect: "error",
    headers: { Authorization: "Bearer " + key },
    signal
  }
}

/**
 * Ask one install for its unread. Resolves (never rejects) to one of
 * `{kind: "ok", unread, as_of}`, `{kind: "stale"}` (failed, timed out, 5xx),
 * `{kind: "reconnect"}` (no key, or 401) and `{kind: "rejected"}` (any other
 * refusal, or a malformed body).
 */
export async function fetchUnread(entry, opts = {}) {
  const fetchImpl = opts.fetch || globalThis.fetch
  const timeoutMs = opts.timeoutMs ?? FETCH_TIMEOUT_MS
  if (!validBadgeKey(entry?.key)) return { kind: "reconnect" }

  const ctrl = typeof AbortController === "function" ? new AbortController() : null
  let timer
  const timeout = new Promise(resolve => {
    timer = setTimeout(() => {
      ctrl?.abort()
      resolve({ kind: "stale" })
    }, timeoutMs)
  })

  const request = (async () => {
    let res
    try {
      res = await fetchImpl(entry.origin + "/api/switcher/unread", unreadRequest(entry.key, ctrl?.signal))
    } catch {
      return { kind: "stale" }
    }
    if (!res || typeof res.status !== "number") return { kind: "rejected" }
    if (res.status === 401) return { kind: "reconnect" }
    if (res.status >= 500) return { kind: "stale" }
    if (res.status !== 200) return { kind: "rejected" }
    const body = await readCapped(res, ctrl)
    const parsed = parseUnread(body)
    return parsed ? { kind: "ok", ...parsed } : { kind: "rejected" }
  })()

  try {
    return await Promise.race([request, timeout])
  } finally {
    clearTimeout(timer)
  }
}

/**
 * The JSON body, or null: refused unread when the declared length or the
 * bytes read pass MAX_BODY_BYTES (the stream is cancelled there), or when it
 * is not JSON. Stage 4: a hostile install's 5 MB answer is never buffered.
 */
async function readCapped(res, ctrl) {
  try {
    const declared = Number(res.headers?.get?.("content-length"))
    if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
      ctrl?.abort()
      return null
    }
    const reader = res.body?.getReader?.()
    if (!reader) return await res.json()
    const chunks = []
    let size = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > MAX_BODY_BYTES) {
        reader.cancel?.().catch?.(() => {})
        ctrl?.abort()
        return null
      }
      chunks.push(value)
    }
    const bytes = new Uint8Array(size)
    let at = 0
    for (const c of chunks) {
      bytes.set(c, at)
      at += c.byteLength
    }
    return JSON.parse(new TextDecoder().decode(bytes))
  } catch {
    return null
  }
}

/**
 * The next row state after an answer. A row state is
 * `{status, unread, as_of}` with status one of loading | ok | stale |
 * unreachable | reconnect | rejected.
 */
export function applyResult(prev, result) {
  const last = prev || { status: "loading", unread: null, as_of: null }
  switch (result?.kind) {
    case "ok": {
      if (last.as_of && Date.parse(result.as_of) < Date.parse(last.as_of)) {
        // An older answer than the one we hold: keep ours.
        return { ...last, status: last.unread == null ? "rejected" : "ok" }
      }
      return { status: "ok", unread: result.unread, as_of: result.as_of }
    }
    case "stale":
      return {
        status: last.unread == null ? "unreachable" : "stale",
        unread: last.unread,
        as_of: last.as_of
      }
    case "reconnect":
      return { status: "reconnect", unread: null, as_of: null }
    default:
      return { status: "rejected", unread: null, as_of: null }
  }
}

/** The initial row state from what storage holds, before any fetch. */
export function initialState(entry) {
  if (!entry.key) return { status: "reconnect", unread: null, as_of: null }
  return { status: "loading", unread: entry.unread, as_of: entry.as_of }
}

/** Whether a row's count may light the closed dot. */
export function countsTowardDot(state) {
  return (
    !!state &&
    (state.status === "ok" || state.status === "stale" || state.status === "loading") &&
    Number.isInteger(state.unread) &&
    state.unread > 0
  )
}

/** The closed-state dot: any OTHER install has unread. */
export function othersHaveUnread(entries, states, currentOrigin) {
  return entries.some(e => e.origin !== currentOrigin && countsTowardDot(states.get(e.origin)))
}

export function formatCount(n) {
  return n > 99 ? "99+" : String(n)
}

/** Run `worker` over `items` with at most `limit` in flight. */
export async function runPool(items, worker, limit = MAX_IN_FLIGHT) {
  const results = new Array(items.length)
  let next = 0
  const lane = async () => {
    while (next < items.length) {
      const i = next++
      try {
        results[i] = await worker(items[i], i)
      } catch (error) {
        results[i] = undefined
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, lane))
  return results
}

/** A local return path (`/x?y`), or "/". Never another host. */
export function safeReturnPath(value) {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) return "/"
  if (value.length > 2048 || /[\s\x00-\x1f\x7f\\#]/.test(value)) return "/"
  if (value.startsWith("/switcher/") || value.startsWith("/auth/")) return "/"
  return value
}
