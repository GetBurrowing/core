// One delegated listener also covers task detail and canvas-rendered content.
// Canvas/prototype links remain owned by ChatViewer's specialized viewer.
export function installInAppLinks(liveSocket, doc = document, win = window) {
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
