// Idempotent loader for the remote terminal island. Same shape as
// js/lib/load_excalidraw.js: cache the promise so concurrent callers share one
// <script>; the island ships a stylesheet (xterm's), so one <link> as well.
//
// Served from our own origin: PlatformWeb.static_paths/0 allowlists "assets".

export const ISLAND_SRC = "/assets/js/terminal_island.js"
export const ISLAND_CSS = "/assets/js/terminal_island.css"

let islandReady = null

export function loadTerminal() {
  if (islandReady) return islandReady

  islandReady = new Promise((resolve, reject) => {
    if (window.__burrow_terminal) {
      resolve(window.__burrow_terminal)
      return
    }

    if (!document.querySelector(`link[href="${ISLAND_CSS}"]`)) {
      const link = document.createElement("link")
      link.rel = "stylesheet"
      link.href = ISLAND_CSS
      document.head.appendChild(link)
    }

    const script = document.createElement("script")
    script.src = ISLAND_SRC
    script.async = true
    script.onload = () =>
      window.__burrow_terminal
        ? resolve(window.__burrow_terminal)
        : reject(new Error(`${ISLAND_SRC} loaded but did not define window.__burrow_terminal`))
    script.onerror = () => reject(new Error(`Failed to load ${ISLAND_SRC}`))
    document.head.appendChild(script)
  })

  islandReady.catch(() => {
    islandReady = null
  })

  return islandReady
}

/** Test seam. */
export function __resetTerminalLoaderForTest() {
  islandReady = null
}

export default loadTerminal
