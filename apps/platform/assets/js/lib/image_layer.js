// The in-app image layer: a full-window overlay for a raw attachment link
// (a canvas image, a task-feed image, a space-sheet Files row).
//
// This file is a MARKUP BUILDER ONLY. It owns no history, key, swipe or
// focus code: it builds the element and hands it to openLayer() in
// dismissable_overlay.js, the one owner of history and exits on the page.
// So the phone's back, Escape, swipe-down and the X all close it through
// the same module that closes the chat viewer, and stacked layers close one
// at a time.
//
// Two modes:
//   - "image": the image, object-contain, on the viewer ground.
//   - "file":  the filename and a Download link. A raw non-image asset is
//     never an in-place navigation of the app.
// Both carry a Download link (the only path to the original file on a
// phone); on a touch device with navigator.share it goes to the share sheet.

import { openLayer, CLOSE_BAR_CLASS, CLOSE_CONTROL_CLASS } from "./dismissable_overlay.js"
import { phoneShare, shareDownload } from "./share_download.js"

const ROOT_CLASS = "fixed inset-0 z-[120] flex flex-col bg-viewer text-on-viewer"

function make(doc, tag, attrs = {}, text) {
  const el = doc.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v)
  if (text != null) el.appendChild(doc.createTextNode(text))
  return el
}

function detach(el) {
  if (el && el.parentNode) el.parentNode.removeChild(el)
}

function filenameFrom(href) {
  try {
    const last = decodeURIComponent(String(href).split(/[?#]/)[0].split("/").pop() || "")
    return last || "attachment"
  } catch (_) {
    return "attachment"
  }
}

/**
 * Build and open an image layer. Returns the dismissable-overlay handle.
 *
 *   - `href`: the raw asset path (/chat/attachments/<uuid>, /files/blob/<id>)
 *   - `mode`: "image" (default) or "file"
 *   - `alt`, `filename`: labels (filename falls back to the path's last part)
 *   - `returnFocusTo`: the anchor that opened it
 *   - `doc`: the document (tests pass a fake)
 */
export function openImageLayer({ href, mode = "image", alt, filename, returnFocusTo, doc = globalThis.document } = {}) {
  const name = filename || alt || filenameFrom(href)
  const root = make(doc, "div", {
    role: "dialog",
    "aria-modal": "true",
    "aria-label": mode === "image" ? alt || name || "Image" : name,
    "data-role": "image-layer",
    "data-mode": mode,
    class: ROOT_CLASS,
  })

  const bar = make(doc, "div", {
    "data-role": "image-layer-bar",
    class: `${CLOSE_BAR_CLASS} flex touch-none items-center gap-1`,
  })
  const close = make(doc, "button", {
    type: "button",
    "data-role": "image-layer-close",
    "aria-label": "Close image",
    class: `${CLOSE_CONTROL_CLASS} btn btn-ghost btn-square size-11`,
  })
  close.appendChild(make(doc, "span", { class: "hero-x-mark size-6", "aria-hidden": "true" }))
  const title = make(
    doc,
    "div",
    { "data-role": "image-layer-filename", class: "min-w-0 flex-1 truncate text-center text-[15px] font-semibold" },
    name,
  )
  const download = make(doc, "a", {
    "data-role": "image-layer-download",
    href,
    download: name,
    "aria-label": "Download",
    class: `${CLOSE_CONTROL_CLASS} btn btn-ghost btn-square size-11`,
  })
  download.appendChild(make(doc, "span", { class: "hero-arrow-down-tray size-5", "aria-hidden": "true" }))
  bar.appendChild(close)
  bar.appendChild(title)
  bar.appendChild(download)
  root.appendChild(bar)

  const stage = make(doc, "div", {
    "data-role": "image-layer-stage",
    class: "flex min-h-0 flex-1 touch-none items-center justify-center p-2",
  })
  if (mode === "image") {
    stage.appendChild(
      make(doc, "img", { src: href, alt: alt || "", class: "max-h-full max-w-full object-contain select-none" }),
    )
  } else {
    const card = make(doc, "div", { class: "flex flex-col items-center gap-4 text-center" })
    card.appendChild(make(doc, "span", { class: "hero-document size-12 opacity-70", "aria-hidden": "true" }))
    card.appendChild(make(doc, "div", { class: "max-w-[80vw] break-words text-[15px] font-semibold" }, name))
    const big = make(
      doc,
      "a",
      { "data-role": "image-layer-download-file", href, download: name, class: "btn btn-primary min-h-11" },
      "Download",
    )
    card.appendChild(big)
    stage.appendChild(card)
  }
  root.appendChild(stage)

  const body = doc.body
  const prevOverflow = body && body.style ? body.style.overflow : undefined
  if (body && body.style) body.style.overflow = "hidden"
  if (body) body.appendChild(root)

  const handle = openLayer({
    el: root,
    swipeTarget: stage,
    returnFocusTo,
    closeControl: close,
    onClose: () => {
      detach(root)
      if (body && body.style) body.style.overflow = prevOverflow || ""
    },
  })

  root.addEventListener("click", (e) => {
    const t = e.target
    if (!t || typeof t.closest !== "function") return
    if (t.closest("[data-role=image-layer-close]")) {
      e.preventDefault()
      handle.close()
      return
    }
    const dl = t.closest("a[download]")
    if (dl && phoneShare()) {
      e.preventDefault()
      e.stopPropagation()
      shareDownload(dl)
    }
  })

  return handle
}
