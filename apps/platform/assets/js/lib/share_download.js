// Hand a downloadable file to the phone's share sheet.
//
// The iOS shell has no download handling (no WKDownload, and it allows every
// same-host main-frame load), so a download anchor there either does nothing
// or navigates the whole web view to the raw file with no way back. On a
// touch device with navigator.share, overlays call shareDownload(anchor)
// instead of following the anchor ("Save Image", "Save to Files").

export function phoneShare() {
  const w = globalThis.window
  return !!(
    typeof navigator !== "undefined" &&
    navigator.share &&
    w &&
    w.matchMedia &&
    w.matchMedia("(pointer: coarse)").matches
  )
}

export function shareDownload(anchor) {
  const href = anchor.getAttribute("href")
  if (!href) return
  const url = /^https?:\/\//i.test(href) ? href : globalThis.window.location.origin + href
  const name = anchor.getAttribute("download") || "attachment"
  const byUrl = () => navigator.share({ url, title: name }).catch(() => {})
  if (typeof fetch !== "function" || typeof File !== "function" || !navigator.canShare) return byUrl()
  fetch(url, { credentials: "same-origin" })
    .then((r) => (r.ok ? r.blob() : Promise.reject(r.status)))
    .then((blob) => {
      const file = new File([blob], name, { type: blob.type })
      return navigator.canShare({ files: [file] }) ? navigator.share({ files: [file], title: name }) : byUrl()
    })
    .catch((err) => {
      // A dismissed sheet is AbortError; only a failed fetch falls back.
      if (!err || err.name !== "AbortError") byUrl()
    })
}
