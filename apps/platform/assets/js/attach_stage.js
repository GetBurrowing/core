// The ONE staging function for the composer's staged tray (redesign rung 11,
// task 01a1557a-9de3). Paste (ComposeInput) and drop (DragDropUpload) both
// call `stageFiles`; files over the composer's inline cap take the chunked
// large-file path (./hooks/large_upload.js), the rest go into LiveView's
// `:attachments` upload, which auto-uploads, so a thumbnail with an upload
// ring shows in the tray at once.
//
// Retry (direction m3 rule 4): a failed entry's thumbnail carries a retry
// glyph (`data-attach-retry="<entry ref>"`). LiveView's entry ref is the
// `_phxRef` it stamps on the File, so this module keeps the Files it staged
// (and the ones picked through the composer's file input) and, on retry,
// cancels the failed ref and stages a copy of the same File.

import { inlineMaxFromDom, partitionFiles, routeFiles, stagedFiles } from "./hooks/large_upload"

const COMPOSE_FORM_ID = "compose-form"
const REMEMBERED_MAX = 50

// Files staged into `:attachments`, newest last, for retry.
const remembered = []

export function rememberFiles(files) {
  for (const f of files) {
    if (!remembered.includes(f)) remembered.push(f)
  }
  while (remembered.length > REMEMBERED_MAX) remembered.shift()
}

export function fileForRef(ref) {
  return remembered.find((f) => f && f._phxRef === ref) || null
}

// Inline files staged within BATCH_MS of each other go to LiveView in ONE
// `uploadTo`: two calls a few milliseconds apart (a paste and a drop, or two
// quick pastes) leave LiveView's image preview looking for a File it has not
// tracked yet, and the second batch never renders (measured on the dev rig:
// back-to-back calls broke, 50ms apart worked).
export const BATCH_MS = 30
let pending = []
let pendingHook = null
let pendingTimer = null

function flush() {
  pendingTimer = null
  const files = pending
  const hook = pendingHook
  pending = []
  pendingHook = null
  const form = document.getElementById(COMPOSE_FORM_ID)
  if (!form || !hook || files.length === 0) return
  hook.uploadTo(form, "attachments", files)
  rememberFiles(files)
}

// Stage files into the tray. Returns how many were staged.
export function stageFiles(hook, files) {
  const list = Array.from(files || [])
  if (list.length === 0) return 0

  const { small, large } = partitionFiles(list, inlineMaxFromDom())
  if (large.length > 0) routeFiles(hook, large)
  if (small.length > 0) {
    pending = pending.concat(small)
    pendingHook = hook
    if (pendingTimer) clearTimeout(pendingTimer)
    pendingTimer = setTimeout(flush, BATCH_MS)
  }
  return list.length
}

// Image items on a clipboard, as Files named `pasted-image-<ts>.<ext>`.
// ALWAYS that name, whatever the blob carries: Chrome hands every pasted
// screenshot over as a File called "image.png" (and mobile browsers a
// nameless blob), so keeping the blob's name gave every paste the same
// "Remove image.png" label. The stamp is unique per file across pastes:
// it never repeats, even for two pastes in the same millisecond.
let lastStamp = 0

export function imageFilesFromClipboard(clipboardData, now = Date.now()) {
  const items = (clipboardData && clipboardData.items) || []
  const files = []
  for (let i = 0; i < items.length; i++) {
    const item = items[i]
    if (!item || item.kind === "string" || !String(item.type || "").startsWith("image/")) continue
    const blob = item.getAsFile && item.getAsFile()
    if (!blob) continue
    const type = blob.type || item.type
    const ext = type.split("/")[1] || "png"
    lastStamp = Math.max(now, lastStamp + 1)
    files.push(new File([blob], `pasted-image-${lastStamp}.${ext}`, { type, lastModified: blob.lastModified }))
  }
  return files
}

export function attachedToastText(count) {
  return count === 1 ? "Image attached" : `${count} images attached`
}

// A short status toast above the composer ("Image attached"). The message
// pill's Copy (hooks/message_gestures.js) reuses it with its own id, a
// `data-role` e2e can find, and its own duration.
export function toast(text, { id = "attach-toast", role = null, ms = 2500 } = {}) {
  if (typeof document === "undefined") return
  let el = document.getElementById(id)
  if (!el) {
    el = document.createElement("div")
    el.id = id
    if (role) el.dataset.role = role
    el.setAttribute("role", "status")
    el.className =
      "pointer-events-none fixed inset-x-0 z-50 mx-auto w-max rounded-box bg-base-content px-3 py-1.5 text-sm text-base-100 shadow-lg"
    document.body.appendChild(el)
  }
  // Just above the composer, whatever its height. The tray that this toast
  // announces grows the composer a moment later, so place it again then.
  const place = () => {
    const form = document.getElementById(COMPOSE_FORM_ID)
    const top = form ? form.getBoundingClientRect().top : window.innerHeight - 140
    el.style.bottom = `${Math.max(window.innerHeight - top + 8, 8)}px`
  }
  place()
  setTimeout(place, 250)
  el.textContent = text
  el.hidden = false
  clearTimeout(el._timer)
  el._timer = setTimeout(() => {
    el.hidden = true
  }, ms)
}

// Delegated click on a failed thumbnail's retry glyph. Installed once; the
// hook passed in is the one that pushes (the composer's ComposeInput).
let retryHook = null
let retryInstalled = false

export function retry(hook, ref) {
  // A transport-failed item (a socket drop interrupted it) is the server's
  // `:attach_failed`, not a LiveView entry.
  const failed = failedFiles.get(ref)
  if (failed) {
    failedFiles.delete(ref)
    hook.pushEvent("attach_failed_remove", { id: ref })
    stageFiles(hook, [new File([failed], failed.name, { type: failed.type, lastModified: failed.lastModified })])
    return true
  }
  const file = fileForRef(ref)
  if (!file) return false
  hook.pushEvent("attach_remove", { ref })
  // A fresh File object gets a fresh LiveView ref; the bytes are the same.
  const copy = new File([file], file.name, { type: file.type, lastModified: file.lastModified })
  stageFiles(hook, [copy])
  return true
}

export function installRetry(hook) {
  retryHook = hook
  if (retryInstalled || typeof document === "undefined") return
  retryInstalled = true
  document.addEventListener("click", (e) => {
    const btn = e.target instanceof Element ? e.target.closest("[data-attach-retry]") : null
    if (!btn || !retryHook) return
    e.preventDefault()
    retry(retryHook, btn.getAttribute("data-attach-retry"))
  })
  // Files picked through the ＋ (the composer's own file input) are staged
  // by LiveView directly; keep them too so they can be retried.
  window.addEventListener(
    "input",
    (e) => {
      const input = e.target
      if (!(input instanceof HTMLInputElement) || input.type !== "file") return
      if (!input.closest(`#${COMPOSE_FORM_ID}`)) return
      rememberFiles(Array.from(input.files || []))
    },
    true,
  )
}

export function releaseRetry(hook) {
  if (retryHook === hook) retryHook = null
}

// A socket drop mid-upload remounts the LiveView with an empty tray (its
// upload entries and staged large files lived in the old process). The
// browser still holds every File, so the composer takes a snapshot when the
// socket drops and, once it is back:
//   - a file that had finished uploading (or had not started: a staged large
//     file) is staged again, quietly;
//   - a file the drop interrupted mid-upload (or one already failed) comes
//     back as a FAILED thumbnail with "Retry <name>" (direction m3 rule 4),
//     reported to the server as `attach_transport_failed`. Retry stages the
//     same File again.
// Nothing staged is lost silently, and nothing failed pretends it did not.

// An upload `progress` push issued in the instant the socket closes is held
// in the LiveView channel's push buffer and sent after the rejoin, to the NEW
// LiveView process, which has never heard of that upload ref: LiveView
// raises (KeyError in `Upload.get_upload_by_ref!/2`) and the view remounts a
// second time, wiping the failed items just reported. Measured on the dev rig
// with `liveSocket.disconnect(); liveSocket.connect()` mid-upload. Every
// entry of the old process is gone anyway, so a buffered progress push is
// always stale: drop it when the socket drops. `pushBuffer` is phoenix.js's
// Channel field; absent, this does nothing.
export function dropBufferedProgress(channel) {
  if (!channel || !Array.isArray(channel.pushBuffer)) return 0
  const before = channel.pushBuffer.length
  channel.pushBuffer = channel.pushBuffer.filter((p) => p && p.event !== "progress")
  return before - channel.pushBuffer.length
}

// The other half of the same crash: each in-flight upload has its own
// `lvu:<ref>` channel, and on a clean socket close (`liveSocket.disconnect()`)
// those channels are not errored, so after the reconnect the uploader keeps
// pushing chunks and `progress` for an entry the new process never had (seen
// as two KeyError crashes in a row on the dev rig). Leave them when the socket
// drops; the interrupted files come back as failed items with Retry instead.
export function leaveUploadChannels(socket) {
  if (!socket || !Array.isArray(socket.channels)) return 0
  let n = 0
  for (const ch of socket.channels.slice()) {
    if (ch && typeof ch.topic === "string" && ch.topic.startsWith("lvu:") && typeof ch.leave === "function") {
      ch.leave()
      n++
    }
  }
  return n
}

// And the third: LiveView's form recovery. On the rejoin it replays the
// composer form's change event, and the live file input still tracks every
// File it ever held (an auto-upload entry that errors is not cleared), so the
// replay re-stages them under the OLD upload ref and the new process raises
// again. The snapshot already holds those Files; forget them on the input
// (what LiveView's own `LiveUploader.clearFiles` does to the `files` private,
// without dropping the upload ref attribute the server re-renders anyway).
export function forgetTrackedFiles(form) {
  if (!form || typeof form.querySelectorAll !== "function") return 0
  let n = 0
  for (const input of form.querySelectorAll("input[type=file][data-phx-upload-ref]")) {
    const priv = input.phxPrivate
    if (priv && Array.isArray(priv.files) && priv.files.length > 0) {
      n += priv.files.length
      priv.files = []
    }
    try {
      input.value = null
    } catch (_e) {
      // A file input's value only takes "" / null; nothing else to do.
    }
  }
  return n
}

// Files of transport-failed items, by the id the server renders them under.
export const failedFiles = new Map()

export function snapshotTray() {
  if (typeof document === "undefined") return { restage: [], failed: [] }
  const snapshot = { restage: [], failed: [] }
  for (const li of document.querySelectorAll("[data-role=staged-tray] li[data-ref], [data-role=staged-tray] li[data-failed-id]")) {
    const failedId = li.getAttribute("data-failed-id")
    if (failedId) {
      const file = failedFiles.get(failedId)
      if (file) snapshot.failed.push({ id: failedId, file })
      continue
    }
    const ref = li.getAttribute("data-ref")
    const large = li.id.startsWith("large-staged-")
    const file = large ? stagedFiles.get(ref) : fileForRef(ref)
    if (!file) continue
    const state = li.getAttribute("data-state")
    const interrupted = !large && (state === "uploading" || (state === "failed" && li.querySelector("[data-attach-retry]")))
    if (interrupted) snapshot.failed.push({ id: ref, file })
    else snapshot.restage.push(file)
  }
  return snapshot
}

// While the socket is down nothing re-renders the tray, so the interrupted
// thumbnails would keep a frozen upload ring until the rejoin. Show them
// failed at once (the outline the server renders for a failed item); the
// rejoin replaces them with the server's failed items and their retry glyph.
export function markInterrupted(snapshot) {
  if (typeof document === "undefined" || !snapshot) return 0
  let n = 0
  for (const { id } of snapshot.failed) {
    const li = document.getElementById(`staged-${id}`)
    if (!li) continue
    li.setAttribute("data-state", "failed")
    const ring = li.querySelector("[data-role=upload-ring]")
    if (ring) ring.remove()
    const frame = li.querySelector("img")?.parentElement || li.querySelector("[data-role=file-chip]")
    if (frame) frame.classList.add("outline", "outline-2", "-outline-offset-2", "outline-error")
    n++
  }
  return n
}

export function restage(hook, snapshot) {
  if (!snapshot) return 0
  const { restage: files = [], failed = [] } = snapshot
  if (files.length === 0 && failed.length === 0) return 0
  if (document.querySelector("[data-role=staged-tray] li[data-ref], [data-role=staged-tray] li[data-failed-id]")) return 0
  if (failed.length > 0) {
    for (const { id, file } of failed) failedFiles.set(id, file)
    hook.pushEvent("attach_transport_failed", {
      files: failed.map(({ id, file }) => ({ id, name: file.name, size: file.size, type: file.type })),
    })
  }
  const copies = files.map((f) => new File([f], f.name, { type: f.type, lastModified: f.lastModified }))
  return stageFiles(hook, copies) + failed.length
}

// The preview of a transport-failed image: the server renders the <img>
// (`Partials.Attach` `failed_item`) and this fills it from the File the
// client kept.
export const AttachFailedPreview = {
  mounted() {
    const file = failedFiles.get(this.el.getAttribute("data-failed-id"))
    if (!file || typeof URL === "undefined" || !URL.createObjectURL) return
    this._url = URL.createObjectURL(file)
    this.el.src = this._url
  },
  destroyed() {
    if (this._url) URL.revokeObjectURL(this._url)
  },
}
