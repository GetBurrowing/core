// LargeUpload — resumable chunked uploads for files over the composer's
// inline cap (task 01a120be).
//
// Files at or under the inline cap keep LiveView's own upload path
// (allow_upload(:attachments)) untouched. A larger file never rides the
// websocket: it is staged with the server ("large_upload_stage"), which decides
// whether it is over the install's limit (the browser holds no limit of its
// own; the inline cap arrives as `data-inline-max` from the server). On Send
// the server reserves it and pushes "large_upload:begin" with a presigned
// upload URL, and the browser PATCHes `chunk_bytes` slices with an
// `Upload-Offset` header (tus-style, see ChatAttachmentUploadController).
//
// WHERE THE STATE LIVES. Every running upload (its `File`, offset, status)
// is in `uploadManager`, a module-level registry. Nothing about an upload
// depends on a hook element surviving: a LiveView rejoin after a reconnect
// re-renders the page and may remount hooks, and the upload keeps running
// through it. The pending card is drawn by JS from the registry into the
// timeline (`LargeUploadTimeline`, a `phx-update="ignore"` container right
// after `#message-list`), and is redrawn whenever that container mounts.
// `app.js` installs a reload guard (../lib/reload_guard.js) that holds
// LiveView's "reload the page to recover" while `uploadManager.isBusy()`,
// because a reload destroys the `File`.
//
// Resume rules:
//   * a network error pauses ("Waiting for connection. Resumes on its own."),
//     waits for `online`, backs off, and re-reads the offset with HEAD before
//     the next PATCH. It never restarts from zero on its own.
//   * a 409 means our offset was stale: adopt the server's Upload-Offset.
//   * a 404 or 410 means the reservation expired (or was reaped) while we
//     were away. The browser still holds the File, so it reserves again
//     through the same server path ("large_upload_rereserve" ->
//     `Chat.reserve_user_upload/2`) and starts again from 0, saying so.
//   * the PATCH that reaches the end answers 200 with the posted message's
//     id; the card stays where it is until that message is in
//     `#message-list`, then the message takes its place.

import { formatBytes, formatEta, formatProgress } from "../lib/byte_format"

const MAX_SERVER_RETRIES = 5
const RESERVE_ATTEMPTS = 5
const MESSAGE_WAIT_MS = 15000
const PUSH_TIMEOUT_MS = 15000

// Picked File objects by staging ref, until Send hands them to the manager.
// Module-level so the drop/paste and file-input routes (which run in other
// hooks) and this hook share it.
export const stagedFiles = new Map()

export function partitionFiles(files, inlineMax) {
  const small = []
  const large = []
  for (const f of files) {
    if (Number.isFinite(inlineMax) && f.size > inlineMax) large.push(f)
    else small.push(f)
  }
  return { small, large }
}

export function inlineMaxFromDom() {
  const root = document.getElementById("large-upload-root")
  const n = root ? parseInt(root.dataset.inlineMax, 10) : NaN
  return Number.isFinite(n) ? n : NaN
}

function newRef() {
  if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID()
  return `lu-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

// Stage every file over the inline cap with the server and return the rest,
// for the caller to hand to LiveView as before. With no `#large-upload-root`
// on the page (no active space), every file is returned untouched.
export function routeFiles(hook, files) {
  const { small, large } = partitionFiles(Array.from(files), inlineMaxFromDom())
  for (const file of large) {
    const ref = newRef()
    stagedFiles.set(ref, file)
    hook.pushEvent("large_upload_stage", {
      ref,
      name: file.name,
      size: file.size,
      type: file.type || "",
    })
  }
  return small
}

function headerInt(res, name) {
  const v = res.headers && res.headers.get(name)
  const n = v == null ? NaN : parseInt(v, 10)
  return Number.isFinite(n) ? n : null
}

const isExpired = (status) => status === 404 || status === 410

/**
 * Upload `u.file` to `u.url` from `u.offset`, `u.chunkBytes` at a time.
 *
 * deps: { fetch, onProgress(sent, status), waitForOnline(), sleep(ms) }
 * Resolves { status: "done", result } | { status: "failed", offset, httpStatus }
 * | { status: "expired", offset, httpStatus } | { status: "aborted", offset }.
 */
export async function runUpload(u, deps) {
  const size = u.file.size
  let offset = u.offset || 0
  let mustHead = !!u.resume
  let serverErrors = 0
  let networkErrors = 0

  const pause = async () => {
    deps.onProgress(offset, "paused")
    await deps.waitForOnline()
    await deps.sleep(Math.min(30000, 1000 * 2 ** Math.min(networkErrors, 5)))
    networkErrors += 1
    mustHead = true
  }

  for (;;) {
    if (u.aborted) return { status: "aborted", offset }

    if (mustHead) {
      let res
      try {
        res = await deps.fetch(u.url, { method: "HEAD", cache: "no-store" })
      } catch (_e) {
        if (u.aborted) return { status: "aborted", offset }
        await pause()
        continue
      }
      if (res.ok) {
        const server = headerInt(res, "upload-offset")
        if (server != null) offset = server
        mustHead = false
        deps.onProgress(offset, "uploading")
      } else if (isExpired(res.status)) {
        return { status: "expired", offset, httpStatus: res.status }
      } else if (res.status >= 500) {
        if (++serverErrors > MAX_SERVER_RETRIES) return { status: "failed", offset, httpStatus: res.status }
        await deps.sleep(Math.min(30000, 1000 * 2 ** serverErrors))
        continue
      } else {
        return { status: "failed", offset, httpStatus: res.status }
      }
    }

    const end = Math.min(offset + u.chunkBytes, size)
    // An in-flight request that the connection dropped under can hang rather
    // than reject; the manager aborts it on `offline`, and that abort is
    // handled like any other network error.
    const inflight = typeof AbortController === "function" ? new AbortController() : null
    u.inflight = inflight
    let res
    try {
      res = await deps.fetch(u.url, {
        method: "PATCH",
        signal: inflight ? inflight.signal : undefined,
        headers: {
          "Upload-Offset": String(offset),
          "Content-Type": "application/offset+octet-stream",
        },
        body: u.file.slice(offset, end),
      })
    } catch (_e) {
      if (u.aborted) return { status: "aborted", offset }
      await pause()
      continue
    } finally {
      u.inflight = null
    }

    if (res.status === 200) {
      let result = null
      try {
        result = await res.json()
      } catch (_e) {
        result = null
      }
      deps.onProgress(size, "uploading")
      return { status: "done", result }
    }

    if (res.status === 204) {
      const server = headerInt(res, "upload-offset")
      offset = server != null ? server : end
      networkErrors = 0
      serverErrors = 0
      deps.onProgress(offset, "uploading")
      continue
    }

    if (res.status === 409) {
      const server = headerInt(res, "upload-offset")
      if (server != null) {
        offset = server
        continue
      }
      mustHead = true
      continue
    }

    if (isExpired(res.status)) return { status: "expired", offset, httpStatus: res.status }

    if (res.status >= 500) {
      if (++serverErrors > MAX_SERVER_RETRIES) return { status: "failed", offset, httpStatus: res.status }
      await deps.sleep(Math.min(30000, 1000 * 2 ** serverErrors))
      mustHead = true
      continue
    }

    return { status: "failed", offset, httpStatus: res.status }
  }
}

// Resolves once the browser says it is online: on the `online` event, or on
// a poll of navigator.onLine (an event can be missed, e.g. while a modal
// dialog holds the page).
function browserWaitForOnline() {
  if (typeof navigator === "undefined" || navigator.onLine !== false) return Promise.resolve()
  return new Promise((resolve) => {
    const done = () => {
      window.removeEventListener("online", done)
      clearInterval(poll)
      resolve()
    }
    const poll = setInterval(() => {
      if (navigator.onLine !== false) done()
    }, 3000)
    window.addEventListener("online", done)
  })
}

const browserSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/**
 * The registry of running uploads. One per page (`uploadManager` below);
 * tests build their own with stubbed `env`.
 *
 * Upload statuses: "uploading" | "paused" | "reserving" (re-reserving after
 * an expiry) | "failed" | "done" (posted; waiting for the message to land).
 */
export class UploadManager {
  constructor(env = {}) {
    this.env = {
      fetch: (...args) => window.fetch(...args),
      waitForOnline: browserWaitForOnline,
      sleep: browserSleep,
      now: () => Date.now(),
      isConnected: () => {
        const ls = typeof window !== "undefined" ? window.liveSocket : null
        return !ls || typeof ls.isConnected !== "function" || ls.isConnected()
      },
      pushTimeoutMs: PUSH_TIMEOUT_MS,
      messageWaitMs: MESSAGE_WAIT_MS,
      ...env,
    }
    this.uploads = new Map() // key (staging ref) -> upload
    this.hooks = new Set() // mounted hooks we can push through
    this.views = new Set() // redraw callbacks (timeline containers)
    this.idleListeners = new Set()
  }

  // ── hooks and views ──────────────────────────────────────────────────

  attachHook(hook) {
    this.hooks.add(hook)
  }

  detachHook(hook) {
    this.hooks.delete(hook)
  }

  addView(fn) {
    this.views.add(fn)
    fn()
  }

  removeView(fn) {
    this.views.delete(fn)
  }

  onIdle(fn) {
    this.idleListeners.add(fn)
    return () => this.idleListeners.delete(fn)
  }

  changed() {
    for (const fn of this.views) {
      try {
        fn()
      } catch (e) {
        console.error("[large-upload] render failed", e)
      }
    }
    if (!this.isBusy()) for (const fn of this.idleListeners) fn()
  }

  // True while any upload holds a File it still has to send. The reload
  // guard and the beforeunload prompt both read this.
  isBusy() {
    for (const u of this.uploads.values()) if (u.active) return true
    return false
  }

  list(spaceId) {
    return [...this.uploads.values()].filter((u) => spaceId == null || u.spaceId === spaceId)
  }

  // ── lifecycle ────────────────────────────────────────────────────────

  // `meta` is one entry of the server's "large_upload:begin" payload.
  begin(meta, file = stagedFiles.get(meta.ref)) {
    if (!file || this.uploads.has(meta.ref)) return null
    stagedFiles.delete(meta.ref)
    const u = {
      key: meta.ref,
      ref: meta.ref,
      id: meta.id,
      url: meta.upload_url,
      chunkBytes: meta.chunk_bytes,
      offset: meta.offset || 0,
      file,
      filename: meta.filename || file.name || "file",
      contentType: meta.content_type || file.type || "",
      byteSize: file.size,
      spaceId: meta.space_id || null,
      participantId: meta.participant_id || null,
      content: meta.content || "",
      startedAt: this.env.now(),
      status: "uploading",
      notice: null,
      failure: null,
      etaS: null,
      samples: [],
      active: false,
      aborted: false,
      messageId: null,
    }
    this.uploads.set(u.key, u)
    this.watchLanding()
    this.run(u, false)
    return u
  }

  async run(u, resume) {
    u.active = true
    u.aborted = false
    u.status = "uploading"
    u.failure = null
    u.resume = resume
    u.samples = [[this.env.now(), u.offset]]
    this.changed()

    const outcome = await runUpload(u, {
      fetch: this.env.fetch,
      waitForOnline: this.env.waitForOnline,
      sleep: this.env.sleep,
      onProgress: (sent, status) => this.progress(u, sent, status),
    })
    if (u.aborted || !this.uploads.has(u.key)) return outcome

    if (outcome.status === "done") {
      u.active = false
      u.status = "done"
      u.offset = u.byteSize
      u.messageId = (outcome.result && outcome.result.message_id) || null
      this.changed()
      this.awaitMessage(u)
    } else if (outcome.status === "expired") {
      await this.reserveAgain(u)
    } else if (outcome.status === "failed") {
      u.active = false
      u.status = "failed"
      u.failure = "finish"
      u.offset = outcome.offset
      this.changed()
    }
    return outcome
  }

  // The reservation is gone (404/410), but the File is still here: reserve
  // again through the server and start again from 0.
  async reserveAgain(u) {
    u.active = true
    u.status = "reserving"
    u.notice = "expired"
    u.failure = null
    u.offset = 0
    this.changed()

    for (let attempt = 0; attempt < RESERVE_ATTEMPTS; attempt++) {
      if (u.aborted) return
      await this.env.waitForOnline()
      const reply = await this.push("large_upload_rereserve", {
        ref: u.ref,
        expired_id: u.id,
        space_id: u.spaceId,
        participant_id: u.participantId,
        filename: u.filename,
        content_type: u.contentType,
        byte_size: u.byteSize,
        content: u.content,
      })
      if (u.aborted) return
      if (reply && reply.ok) {
        u.id = reply.id
        u.url = reply.upload_url
        u.chunkBytes = reply.chunk_bytes || u.chunkBytes
        u.offset = reply.offset || 0
        await this.run(u, false)
        return
      }
      // A definite refusal from the server: retrying will not change it.
      if (reply && reply.ok === false) break
      await this.env.sleep(Math.min(30000, 1000 * 2 ** attempt))
    }

    u.active = false
    u.status = "failed"
    u.failure = "reserve"
    this.changed()
  }

  progress(u, sent, status) {
    const now = this.env.now()
    // The rate is measured since the last resume: time spent offline is not
    // upload time, and counting it reads "about 107 min" right after a drop.
    if (status !== "paused" && u.status === "paused") u.samples = [[now, sent]]
    u.offset = sent
    u.status = status === "paused" ? "paused" : "uploading"
    u.samples.push([now, sent])
    while (u.samples.length > 2 && now - u.samples[0][0] > 20000) u.samples.shift()
    u.etaS = null
    if (u.samples.length > 1) {
      const [t0, s0] = u.samples[0]
      const rate = (sent - s0) / Math.max(1, (now - t0) / 1000)
      if (rate > 0) u.etaS = Math.round((u.byteSize - sent) / rate)
    }
    this.changed()
  }

  cancel(key) {
    const u = this.uploads.get(key)
    if (!u) return
    u.aborted = true
    u.active = false
    if (u.inflight) u.inflight.abort()
    this.uploads.delete(key)
    if (u.posterUrl && typeof URL !== "undefined") URL.revokeObjectURL(u.posterUrl)
    if (u.id && u.status !== "done") this.push("large_upload_cancel", { id: u.id })
    this.changed()
  }

  retry(key) {
    const u = this.uploads.get(key)
    if (!u || u.status !== "failed") return
    if (u.failure === "reserve") this.reserveAgain(u)
    else this.run(u, true)
  }

  // Called on the browser's `offline`: an in-flight PATCH can hang instead
  // of rejecting, so abort it and let the loop pause.
  abortInflight() {
    for (const u of this.uploads.values()) if (u.inflight) u.inflight.abort()
  }

  // The message is posted by the server on the final PATCH, and its PubSub
  // broadcast can reach this page BEFORE the 200 does. Either way the card
  // stays where it is until the posted message is in `#message-list` (found
  // by the message id from the 200, or by its attachment URL, which carries
  // the reservation id), and is dropped in the same task: a MutationObserver
  // callback runs before the next paint, so the message takes the card's
  // place without a frame in which both, or neither, are on screen.
  landed(u) {
    if (typeof document === "undefined") return false
    const list = document.getElementById("message-list")
    if (!list) return false
    if (u.messageId != null && list.querySelector(`[data-message-id="${CSS.escape(String(u.messageId))}"]`)) {
      return true
    }
    if (u.id != null && u.offset > 0) {
      const url = `/chat/attachments/${u.id}`
      if (list.querySelector(`[src="${CSS.escape(url)}"], [href="${CSS.escape(url)}"]`)) return true
    }
    return false
  }

  drop(u) {
    if (u.dropTimer) clearTimeout(u.dropTimer)
    u.dropTimer = null
    u.active = false
    if (this.uploads.get(u.key) !== u) return
    const row = typeof document !== "undefined" ? document.getElementById(rowId(u)) : null
    const container = row && row.parentNode
    const scroller = container && container.closest ? container.closest("[data-scroll-container]") : null
    this.uploads.delete(u.key)
    if (u.posterUrl && typeof URL !== "undefined") URL.revokeObjectURL(u.posterUrl)
    this.changed()
    holdPostedCard(u, container, scroller)
  }

  // One observer for the page's lifetime, created when the timeline first
  // mounts (page load): MutationObserver callbacks run in creation order, so
  // the swap and its scroll correction happen before any observer created
  // later sees the DOM, and before the next paint.
  watchLanding() {
    if (this.observer || typeof MutationObserver !== "function" || typeof document === "undefined") return
    this.observer = new MutationObserver(() => {
      if (this.uploads.size === 0) return
      for (const u of [...this.uploads.values()]) {
        if (u.status !== "failed" && this.landed(u)) this.drop(u)
      }
    })
    this.observer.observe(document.body, { childList: true, subtree: true })
  }

  awaitMessage(u) {
    if (typeof document === "undefined" || this.landed(u)) return this.drop(u)
    this.watchLanding()
    // The message normally lands within a second; never leave a finished
    // card on screen for good if it does not (another tab, a filtered view).
    u.dropTimer = setTimeout(() => this.drop(u), this.env.messageWaitMs)
  }

  // Push through any mounted hook, once the socket is up. Resolves the reply,
  // or null when there was no connection or no reply in time (the caller
  // retries). Never throws.
  async push(event, payload) {
    const deadline = this.env.now() + this.env.pushTimeoutMs
    let hook = null
    for (;;) {
      hook = [...this.hooks][this.hooks.size - 1] || null
      if (hook && this.env.isConnected()) break
      if (this.env.now() >= deadline) return null
      await this.env.sleep(500)
    }
    return new Promise((resolve) => {
      let settled = false
      const timer = setTimeout(() => {
        settled = true
        resolve(null)
      }, this.env.pushTimeoutMs)
      try {
        const maybe = hook.pushEvent(event, payload, (reply) => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          resolve(reply || {})
        })
        // LiveView 1.x returns a promise too; a rejected one is a timeout.
        if (maybe && typeof maybe.catch === "function") maybe.catch(() => {})
      } catch (_e) {
        settled = true
        clearTimeout(timer)
        resolve(null)
      }
    })
  }
}

export const uploadManager = new UploadManager()

let windowListenersInstalled = false
function installWindowListeners() {
  if (windowListenersInstalled || typeof window === "undefined") return
  windowListenersInstalled = true
  window.addEventListener("offline", () => uploadManager.abortInflight())
  // Secondary guard only: the File cannot survive a reload, so ask first.
  window.addEventListener("beforeunload", (e) => {
    if (uploadManager.isBusy()) {
      e.preventDefault()
      e.returnValue = ""
    }
  })
}

// ── Pending card (drawn into the timeline) ────────────────────────────

const rowId = (u) => `large-upload-row-${u.key}`
const isVideo = (u) => (u.contentType || "").startsWith("video/")

function el(tag, className, text) {
  const n = document.createElement(tag)
  if (className) n.className = className
  if (text != null) n.textContent = text
  return n
}

function button(label, onClick) {
  const b = el("button", "btn btn-ghost btn-xs shrink-0", label)
  b.type = "button"
  b.addEventListener("click", (e) => {
    e.preventDefault()
    e.stopPropagation()
    onClick()
  })
  return b
}

// The row is the sender's own message row (template rendered by the server
// with the real avatar and name, `#large-upload-row-template`), and the card
// inside it is the posted attachment at its final size: for a video, the
// same `max-w-md` box with an `aspect-video` frame and one `py-2` line under
// it; for any other file, the same paper-clip chip. Only the 3px bar along
// the bottom edge and the counter differ, and both go when it is done.
function buildRow(u, manager) {
  const tpl = document.getElementById("large-upload-row-template")
  let row
  if (tpl && tpl.content && tpl.content.firstElementChild) {
    row = tpl.content.firstElementChild.cloneNode(true)
  } else {
    row = el("div", "group relative rounded-2xl bg-base-200/60")
    row.setAttribute("data-role", "large-upload-row")
    const inner = el("div", "message-row-inner flex gap-3 px-2 py-2 rounded-2xl")
    const body = el("div", "flex-1 min-w-0")
    body.setAttribute("data-slot", "body")
    inner.appendChild(body)
    row.appendChild(inner)
  }
  row.id = rowId(u)
  row.dataset.key = u.key
  const time = row.querySelector('[data-slot="time"]')
  if (time) {
    time.textContent = new Date(u.startedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
  }
  const body = row.querySelector('[data-slot="body"]') || row

  if (u.content && u.content.trim() !== "") {
    body.appendChild(el("div", "text-sm text-base-content break-words chat-markdown", u.content))
  }

  const wrap = el("div", "mt-1 flex flex-col gap-2")
  let card
  const counter = el("span", "shrink-0 font-mono text-[11px] tabular-nums text-subtle")
  counter.setAttribute("data-role", "large-upload-counter")
  if (isVideo(u)) {
    card = el("div", "relative w-full max-w-md overflow-hidden rounded-box border border-edge bg-base-200")
    const frame = el("div", "aspect-video w-full bg-base-300")
    frame.setAttribute("data-role", "large-upload-poster")
    if (typeof URL !== "undefined" && URL.createObjectURL) {
      const v = document.createElement("video")
      u.posterUrl = u.posterUrl || URL.createObjectURL(u.file)
      v.src = u.posterUrl
      v.preload = "metadata"
      v.muted = true
      v.playsInline = true
      v.className = "h-full w-full"
      frame.appendChild(v)
    }
    const line = el("div", "flex items-center gap-2 px-3 py-2 text-sm")
    const name = el("span", "min-w-0 flex-1 truncate", u.filename)
    name.title = u.filename
    line.appendChild(name)
    line.appendChild(counter)
    const cancel = button("Cancel", () => manager.cancel(u.key))
    cancel.setAttribute("data-role", "large-upload-cancel")
    line.appendChild(cancel)
    card.appendChild(frame)
    card.appendChild(line)
  } else {
    card = el(
      "span",
      "relative inline-flex w-fit items-center gap-2 overflow-hidden rounded bg-base-200 px-2 py-1 text-sm text-primary",
    )
    card.appendChild(el("span", "hero-paper-clip size-4"))
    card.appendChild(el("span", null, u.filename))
    card.appendChild(el("span", "text-xs text-subtle", `(${formatBytes(u.byteSize)})`))
  }
  card.setAttribute("data-role", "large-upload-card")
  const track = el("div", "absolute inset-x-0 bottom-0 h-[3px] bg-base-300")
  track.setAttribute("aria-hidden", "true")
  track.setAttribute("data-role", "large-upload-track")
  const bar = el("div", "h-full bg-primary")
  bar.setAttribute("data-role", "large-upload-bar")
  track.appendChild(bar)
  card.appendChild(track)
  wrap.appendChild(card)
  body.appendChild(wrap)

  // Everything under the card goes when the upload is done, so removing it
  // never moves the card.
  const below = el("div", "")
  below.setAttribute("data-role", "large-upload-below")
  body.appendChild(below)
  // The chip has no room for the counter, so it sits on the first line below.
  if (!isVideo(u)) row._counterBelow = counter
  row._counter = counter
  return row
}

function statusLine(u, manager) {
  const frag = document.createDocumentFragment()
  const line = el("div", "mt-1 flex items-center gap-2 text-xs text-subtle")
  line.setAttribute("data-role", "large-upload-status")
  if (u.status === "failed") {
    const icon = el("span", "hero-exclamation-circle size-4 shrink-0 text-error")
    icon.setAttribute("aria-hidden", "true")
    line.appendChild(icon)
    const msg =
      u.failure === "reserve"
        ? "The upload expired and could not be started again."
        : `Could not finish. ${formatProgress(u.offset, u.byteSize)} kept.`
    line.appendChild(el("span", "min-w-0 flex-1 text-base-content", msg))
    const again = button("Try again", () => manager.retry(u.key))
    again.setAttribute("data-role", "large-upload-retry")
    line.appendChild(again)
    line.appendChild(button("Remove", () => manager.cancel(u.key)))
    frag.appendChild(line)
    return frag
  }
  const words = []
  if (u.status === "paused") words.push("Waiting for connection. Resumes on its own.")
  else if (u.notice === "expired") words.push("The upload expired while offline. Starting again.")
  if (words.length > 0) {
    line.appendChild(el("span", "min-w-0 flex-1", words.join(" ")))
    frag.appendChild(line)
  }
  frag.appendChild(el("p", "mt-1 text-xs text-subtle", "Keep this tab open until it finishes."))
  return frag
}

function updateRow(row, u, manager) {
  const card = row.querySelector('[data-role="large-upload-card"]')
  if (card) card.setAttribute("data-status", u.status)
  row.setAttribute("data-status", u.status)
  const done = u.status === "done"
  const counter = row._counter || row.querySelector('[data-role="large-upload-counter"]')
  if (counter) {
    counter.textContent = done
      ? formatBytes(u.byteSize)
      : `${formatProgress(u.offset, u.byteSize)}${u.status === "uploading" ? formatEta(u.etaS) : ""}`
  }
  const bar = row.querySelector('[data-role="large-upload-bar"]')
  if (bar) {
    const pct = u.byteSize > 0 ? Math.min(100, (u.offset * 100) / u.byteSize) : 0
    bar.style.width = `${pct.toFixed(1)}%`
  }
  const track = row.querySelector('[data-role="large-upload-track"]')
  if (track) track.hidden = done
  const cancel = row.querySelector('[data-role="large-upload-cancel"]')
  if (cancel) cancel.style.visibility = done || u.status === "failed" ? "hidden" : ""

  // From 'done' until the posted message takes the card's place, the lines
  // under the card stay in the layout, invisible: removing them would make
  // the content shorter, and a scroller pinned to the bottom would clamp its
  // scrollTop and move the card down by their height.
  //
  // A row BUILT at 'done' (the timeline container was remounted, or the row
  // rebuilt, between done and the swap; task 01a127bd) starts with an empty
  // `below`, so it is filled here with the lines the last live state showed:
  // the row must be as tall as the one it replaces, or the card moves.
  const below = row.querySelector('[data-role="large-upload-below"]')
  if (below) {
    below.style.visibility = done ? "hidden" : ""
    if (!done) fillBelow(below, row, u, manager, { asStatus: u.status })
    else if (!below.firstElementChild) fillBelow(below, row, u, manager, { asStatus: "uploading" })
  }
}

// The lines under the card: the chip's counter line (with its Cancel) for a
// non-video upload, then the status line(s), drawn as if the upload were in
// `asStatus`.
function fillBelow(below, row, u, manager, { asStatus }) {
  below.replaceChildren()
  if (row._counterBelow && asStatus !== "failed") {
    const l = el("div", "mt-1 flex items-center gap-2")
    l.appendChild(row._counterBelow)
    const c = button("Cancel", () => manager.cancel(u.key))
    c.setAttribute("data-role", "large-upload-cancel")
    if (u.status === "done") c.style.visibility = "hidden"
    l.appendChild(c)
    below.appendChild(l)
  }
  below.appendChild(statusLine(asStatus === u.status ? u : { ...u, status: asStatus, notice: null }, manager))
}

// Where the pending card is painted, recorded at every render and on every
// scroll of the scroller (never inside the landing MutationObserver: by then
// the posted message is in the DOM and ScrollToBottom may already have
// scrolled). drop() holds the posted card at this y.
function recordCardTops(container, manager) {
  for (const u of manager.list(container.dataset.spaceId || null)) {
    const row = container.querySelector(`#${CSS.escape(rowId(u))}`)
    const card = row && row.querySelector('[data-role="large-upload-card"]')
    if (card) u.cardTop = card.getBoundingClientRect().top
  }
}

// The posted message's attachment card: the video card, or the chip.
function postedCard(u) {
  const list = document.getElementById("message-list")
  if (!list) return null
  let msg = u.messageId != null ? list.querySelector(`[data-message-id="${CSS.escape(String(u.messageId))}"]`) : null
  if (!msg && u.id != null) {
    const url = CSS.escape(`/chat/attachments/${u.id}`)
    const hit = list.querySelector(`[src="${url}"], [href="${url}"]`)
    msg = hit && hit.closest("[data-message-id]")
  }
  if (!msg) return null
  return msg.querySelector('[data-role="video-attachment"]') || msg.querySelector('a[href^="/chat/attachments/"]')
}

// After the swap, put the posted card where the pending card was painted.
// The posted row is shorter than the pending one (no lines under the card),
// so with the scroller pinned to the bottom the browser clamps scrollTop and
// the card would move; scroll by the difference, and when that is past the
// end of the content, first make up the shortfall with padding on the
// timeline container (cleared when the next message or upload arrives).
function holdPostedCard(u, container, scroller) {
  if (u.cardTop == null || !container || !scroller) return
  const card = postedCard(u)
  if (!card) return
  const delta = card.getBoundingClientRect().top - u.cardTop
  if (Math.abs(delta) < 0.5) return
  const want = scroller.scrollTop + delta
  const max = scroller.scrollHeight - scroller.clientHeight
  if (want > max) {
    const pad = parseFloat(container.style.paddingBottom || "0") || 0
    container.style.paddingBottom = `${pad + (want - max)}px`
    watchPadding(container)
  }
  scroller.scrollTop = want
}

function clearPadding(container) {
  if (container.style.paddingBottom) container.style.paddingBottom = ""
  if (container._padObserver) container._padObserver.disconnect()
  container._padObserver = null
}

// The next message in the list, or the next upload row, makes the content
// grow and auto-scroll takes over: the padding has done its job.
function watchPadding(container) {
  if (container._padObserver || typeof MutationObserver !== "function") return
  const list = document.getElementById("message-list")
  if (!list) return
  container._padObserver = new MutationObserver((records) => {
    if (records.some((r) => r.addedNodes && r.addedNodes.length > 0)) clearPadding(container)
  })
  container._padObserver.observe(list, { childList: true })
}

// The day separator a posted message carries when it is the first of its
// (UTC) day: the same markup as `chat_message/1`'s, inside the row, so the
// card sits where the posted message's card will.
function daySeparator() {
  const sep = el("div", "js-date-separator flex items-center gap-3 my-4 -mx-2")
  sep.setAttribute("data-role", "large-upload-day")
  sep.appendChild(el("div", "flex-1 border-t border-edge"))
  sep.appendChild(el("span", "text-[11px] uppercase tracking-widest text-subtle font-semibold px-2", "Today"))
  sep.appendChild(el("div", "flex-1 border-t border-edge"))
  return sep
}

// Spacing that puts the row exactly where the posted message will appear:
// `#message-list` ends with 16px of padding, and its rows are 4px apart
// (`space-y-1`), or flush when a row continues the author above it (the
// grouping rule of ScrollToBottom.applyGrouping). The first message of a
// UTC day opens with a day separator.
function placeRows(container, rows) {
  const list = document.getElementById("message-list")
  const lastListRow = list ? [...list.querySelectorAll(":scope > [data-participant-id]")].pop() : null
  let prevPid = lastListRow ? lastListRow.dataset.participantId : null
  const today = new Date().toISOString().slice(0, 10)
  const newDay = !lastListRow || lastListRow.dataset.date !== today
  rows.forEach((row, i) => {
    const pid = row.dataset.participantId || null
    const grouped = pid != null && pid === prevPid
    row.classList.toggle("message-row--grouped", grouped)
    const gap = grouped ? 0 : 4
    row.style.marginTop = `${i === 0 ? gap - 16 : gap}px`
    row.style.marginBottom = i === rows.length - 1 ? "16px" : "0px"
    const sep = row.querySelector(':scope > [data-role="large-upload-day"]')
    if (i === 0 && newDay && !sep) row.insertBefore(daySeparator(), row.firstChild)
    if ((i > 0 || !newDay) && sep) sep.remove()
    prevPid = pid
  })
}

export function renderTimeline(container, manager = uploadManager) {
  const spaceId = container.dataset.spaceId || null
  const want = manager.list(spaceId)
  const keep = new Set(want.map(rowId))
  for (const row of [...container.children]) if (!keep.has(row.id)) row.remove()
  let added = false
  const rows = []
  for (const u of want) {
    let row = container.querySelector(`#${CSS.escape(rowId(u))}`)
    if (!row) {
      clearPadding(container)
      row = buildRow(u, manager)
      container.appendChild(row)
      added = true
    }
    updateRow(row, u, manager)
    rows.push(row)
  }
  placeRows(container, rows)
  if (added) {
    const scroller = container.closest("[data-scroll-container]")
    if (scroller && scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 400) {
      scroller.scrollTop = scroller.scrollHeight
    }
  }
  recordCardTops(container, manager)
}

// ── Hooks ─────────────────────────────────────────────────────────────

// On the timeline container after `#message-list`. phx-update="ignore", so
// LiveView never touches the rows JS draws; on (re)mount it redraws them from
// the registry, which is what carries the card through a reconnect.
export const LargeUploadTimeline = {
  mounted() {
    uploadManager.attachHook(this)
    uploadManager.watchLanding()
    this._draw = () => renderTimeline(this.el, uploadManager)
    uploadManager.addView(this._draw)
    this._scroller = this.el.closest("[data-scroll-container]")
    this._onScroll = () => recordCardTops(this.el, uploadManager)
    if (this._scroller) this._scroller.addEventListener("scroll", this._onScroll, { passive: true })
  },
  destroyed() {
    if (this._scroller) this._scroller.removeEventListener("scroll", this._onScroll)
    clearPadding(this.el)
    uploadManager.removeView(this._draw)
    uploadManager.detachHook(this)
  },
}

// On `#large-upload-root` in the composer: takes large files out of the
// composer's file input, and starts the uploads the server reserved.
const LargeUpload = {
  mounted() {
    installWindowListeners()
    uploadManager.attachHook(this)

    this.handleEvent("large_upload:begin", ({ uploads }) => {
      for (const meta of uploads || []) uploadManager.begin(meta)
    })
    this.handleEvent("large_upload:forget", ({ ref }) => {
      stagedFiles.delete(ref)
    })

    // Files picked through the composer's file input (the ＋) reach
    // LiveView's own window listeners in the bubble phase; these
    // capture-phase listeners run first and take the large files out.
    // Pasted and dropped files are routed before they reach the input
    // (../attach_stage.js `stageFiles`).
    this._onFileInput = (e) => {
      const input = e.target
      if (!(input instanceof HTMLInputElement) || input.type !== "file") return
      if (!input.closest("#compose-form")) return
      const files = Array.from(input.files || [])
      const small = routeFiles(this, files)
      if (small.length === files.length) return
      const dt = new DataTransfer()
      small.forEach((f) => dt.items.add(f))
      input.files = dt.files
      if (small.length === 0) e.stopImmediatePropagation()
    }

    window.addEventListener("change", this._onFileInput, true)
    window.addEventListener("input", this._onFileInput, true)
  },

  destroyed() {
    // The uploads are NOT stopped: they live in `uploadManager`, not here.
    window.removeEventListener("change", this._onFileInput, true)
    window.removeEventListener("input", this._onFileInput, true)
    uploadManager.detachHook(this)
  },
}

export default LargeUpload
