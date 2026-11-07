// This page never creates a voice client. Burrow owns the ongoing call.
export function unsupportedPlatform(nav) {
  const platform = `${nav.userAgentData?.platform || ""} ${nav.platform || ""} ${nav.userAgent || ""}`
  if (/Windows|Win32|Win64/i.test(platform)) return false
  return /Mac|iPhone|iPad|Android|Linux/i.test(platform)
}

export function downloadAcknowledged(cookie, nonce) {
  return cookie.split(";").some(part => part.trim() === `burrow_game_download=${nonce}`)
}

export function startDownloadTracking({readCookie, nonce, onStarted, onTimeout, schedule, cancel}) {
  let elapsed = 0
  const timer = schedule(() => {
    elapsed += 250
    if (downloadAcknowledged(readCookie(), nonce)) {
      cancel(timer)
      onStarted()
    } else if (elapsed >= 20000) {
      cancel(timer)
      onTimeout()
    }
  }, 250)
  return () => cancel(timer)
}

export function installPublicGamePage(doc = document, win = window) {
  const root = doc.getElementById("public-game")
  if (!root) return
  const action = root.querySelector("[data-game-action]")
  const unsupported = root.querySelector("[data-game-unsupported]")
  const status = root.querySelector("[data-game-status]")
  const setup = root.querySelector("[data-game-setup]")
  if (action && unsupported) {
    const nonWindows = unsupportedPlatform(win.navigator)
    unsupported.hidden = !nonWindows
    action.hidden = nonWindows
  }
  root.dataset.gamePageReady = "true"
  let stop = null, frame = null
  root.addEventListener("click", async event => {
    const button = event.target.closest("[data-game-copy], [data-game-download], [data-game-windows-override]")
    if (!button) return
    if (button.hasAttribute("data-game-windows-override")) {
      event.preventDefault()
      unsupported.hidden = true
      action.hidden = false
      return
    }
    if (button.hasAttribute("data-game-copy")) {
      event.preventDefault()
      const url = win.location.origin + win.location.pathname
      try {
        await win.navigator.clipboard.writeText(url)
        status.textContent = "Game link copied. Open it on your Windows PC."
      } catch (_) {
        const input = root.querySelector("[data-game-copy-fallback]")
        input.hidden = false
        input.value = url
        input.focus()
        input.select()
        status.textContent = "Copy this link to open on your Windows PC."
      }
      return
    }
    // Without Web Crypto, the ordinary download link remains functional.
    if (!win.crypto?.getRandomValues) return
    event.preventDefault()
    if (root.dataset.downloadState === "pending") return
    const nonce = Array.from(win.crypto.getRandomValues(new Uint8Array(16)), n => n.toString(16).padStart(2, "0")).join("")
    const url = new URL(button.href, win.location.href)
    url.searchParams.set("download_request", nonce)
    root.dataset.downloadState = "pending"
    status.textContent = "Starting your download…"
    stop?.()
    frame?.remove()
    frame = doc.createElement("iframe")
    frame.hidden = true
    frame.title = "Game download"
    frame.src = url.href
    root.appendChild(frame)
    stop = startDownloadTracking({
      readCookie: () => doc.cookie, nonce,
      schedule: win.setInterval.bind(win), cancel: win.clearInterval.bind(win),
      onStarted: () => {
        root.dataset.downloadState = "started"
        action.hidden = true
        unsupported.hidden = true
        setup.hidden = false
        status.textContent = "Your download has started. Follow the setup steps below."
        doc.cookie = "burrow_game_download=; Max-Age=0; Path=/; SameSite=Lax"
      },
      onTimeout: () => {
        root.dataset.downloadState = "idle"
        status.textContent = "No download confirmation yet. Check Downloads, or sign in again and retry."
      },
    })
  })
  win.addEventListener("pagehide", () => stop?.(), {once: true})
}
