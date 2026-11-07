import { openImageLayer as defaultOpenImageLayer } from "./image_layer.js"

// One delegated listener also covers task detail and canvas-rendered content.
// Canvas/prototype links remain owned by ChatViewer's specialized viewer.
//
// Raw assets are never navigated to. /chat/attachments/<uuid> and
// /files/blob/<id> are controller routes, so historyRedirect (or
// location.assign) would replace the whole app with a bare file document,
// and inside the iOS shell there is no back UI to leave it. An image anchor
// (data-image-viewer, or one wrapping an <img>) opens the in-app image layer;
// any other raw asset opens that layer in file mode. The href stays as the
// no-JS fallback.
const RAW_ASSET_PATH =
  /^\/chat\/attachments\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$|^\/files\/blob\/[^/]+/i

export function rawAssetPath(pathname) {
  return RAW_ASSET_PATH.test(pathname || "")
}

function imageAnchor(anchor) {
  if (anchor.hasAttribute("data-image-viewer")) return true
  return !!(typeof anchor.querySelector === "function" && anchor.querySelector("img"))
}

export function installInAppLinks(
  liveSocket,
  doc = document,
  win = window,
  { openImageLayer = defaultOpenImageLayer } = {},
) {
  const onClick = (event) => {
    const clickedAnchor = event.target.closest?.("a[href]")
    const clickedHref = clickedAnchor?.getAttribute("href")
    // Sanitized unsafe URLs must not trigger even a fragment/new-window navigation.
    if (clickedHref === "#blocked" || clickedHref?.startsWith("#blocked:")) {
      event.preventDefault()
      event.stopPropagation()
      return
    }
    if (event.defaultPrevented || event.button !== 0 || event.metaKey ||
        event.ctrlKey || event.shiftKey || event.altKey) return
    const anchor = event.target.closest?.('a[data-in-app-link="path"]')
    if (!anchor || anchor.hasAttribute("download")) return
    const href = anchor.getAttribute("href")
    if (!href || href === "#blocked") return
    const url = new URL(href, win.location.href)
    if (url.origin !== win.location.origin || !/^https?:$/.test(url.protocol)) return
    event.preventDefault()
    // LiveView's window listener does not honor defaultPrevented.
    event.stopPropagation()
    const path = url.pathname + url.search + url.hash
    if (rawAssetPath(url.pathname)) {
      const img = typeof anchor.querySelector === "function" ? anchor.querySelector("img") : null
      openImageLayer({
        href: path,
        mode: imageAnchor(anchor) ? "image" : "file",
        alt: (img && img.getAttribute("alt")) || anchor.getAttribute("data-filename") || "",
        filename: anchor.getAttribute("data-filename") || undefined,
        returnFocusTo: anchor,
      })
      return
    }
    if (liveSocket && typeof liveSocket.historyRedirect === "function") {
      // Cross-LiveView navigation; LiveView falls back to a same-window
      // redirect when the destination cannot be mounted as a LiveView.
      liveSocket.historyRedirect(event, path, "push", null, anchor)
    } else {
      win.location.assign(path)
    }
  }
  doc.addEventListener("click", onClick)
  return () => doc.removeEventListener("click", onClick)
}
