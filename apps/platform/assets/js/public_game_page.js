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

// Arrow keys step through screenshots and wrap at either end.
export function stepIndex(index, delta, count) {
  return count > 0 ? (index + delta + count) % count : 0
}

// Thumbnails are plain links to the image; with a dialog available they open
// the viewer instead. Arrow keys move between thumbnails and inside the viewer.
export function installGameGallery(root) {
  const gallery = root.querySelector("[data-game-gallery]")
  const dialog = gallery?.querySelector("[data-game-lightbox]")
  if (!gallery) return
  const shots = Array.from(gallery.querySelectorAll("[data-game-shot]"))
  const image = dialog?.querySelector("[data-game-lightbox-image]")
  const caption = dialog?.querySelector("[data-game-lightbox-caption]")
  const count = dialog?.querySelector("[data-game-lightbox-count]")
  let current = 0
  const show = index => {
    current = stepIndex(index, 0, shots.length)
    const shot = shots[current]
    image.src = shot.getAttribute("href")
    // The visible caption falls back to the alt text; when a caption is its
    // own words, the image keeps the alt so neither is lost in the viewer.
    const alt = shot.dataset.gameShotAlt
    const label = shot.dataset.gameShotCaption || alt
    caption.textContent = label
    image.alt = label === alt ? "" : alt
    count.textContent = `${current + 1} / ${shots.length}`
  }
  gallery.addEventListener("keydown", event => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return
    const delta = event.key === "ArrowLeft" ? -1 : 1
    if (dialog?.open) {
      event.preventDefault()
      show(current + delta)
    } else if (event.target.matches?.("[data-game-shot]")) {
      event.preventDefault()
      shots[stepIndex(shots.indexOf(event.target), delta, shots.length)].focus()
    }
  })
  if (!dialog || typeof dialog.showModal !== "function") return
  gallery.addEventListener("click", event => {
    const shot = event.target.closest("[data-game-shot]")
    const step = event.target.closest("[data-game-lightbox-step]")
    if (shot) {
      event.preventDefault()
      show(shots.indexOf(shot))
      dialog.showModal()
    } else if (step) {
      show(current + Number(step.dataset.gameLightboxStep))
    } else if (event.target.closest("[data-game-lightbox-close]") || event.target === dialog) {
      dialog.close()
    }
  })
  // Closing returns focus to the screenshot that is showing. The browser
  // restores focus to the opener first, so this runs after it.
  dialog.addEventListener("close", () => setTimeout(() => shots[current]?.focus(), 0))
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
  const resize = () => root.style.setProperty("--game-viewport-height", `${win.visualViewport?.height || win.innerHeight}px`)
  resize()
  win.visualViewport?.addEventListener("resize", resize)
  win.addEventListener("resize", resize)
  installGameGallery(root)
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
  win.addEventListener("pagehide", () => {
    stop?.()
    win.visualViewport?.removeEventListener("resize", resize)
    win.removeEventListener("resize", resize)
  }, {once: true})
}
