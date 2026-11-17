// Lock-screen card and in-call tab title (task 01a1e82a stage 3).
//
// While in a call:
//   - the Media Session card (phone lock screen, OS media flyouts) reads
//     "In <name>" / "<names> · mic on" / elapsed, with Mute (togglemicrophone),
//     camera and Leave (hangup) wired to the same paths the top bar uses;
//   - a tab that is not the call room is titled "● 12:04 <name> · <app>",
//     or "● ↻ 0:07 <name> · <app>" while LiveKit reconnects.
// On leave / end both are cleared and the page's own title comes back.
//
// Inside the iOS app the native call (CallKit) owns the lock screen, so the
// Media Session half stays off there; the title half still runs.
//
// `createMeetingMediaSession(env)` takes everything it touches through
// `env` (media session, title get/set, the presence state, the routes for
// the actions, timers) so vitest drives it without a DOM. It is wired up in
// `installMeetingPresence` (meeting_presence.js).

import { formatElapsed } from "./hooks/meeting_bar.js"

export const METADATA_REFRESH_MS = 15000
export const TICK_MS = 1000
const ACTIONS = ["togglemicrophone", "togglecamera", "hangup"]

// "Sam", "Sam and Lee", "Sam, Lee and Ana", "Sam, Lee, Ana and 2 others".
export function rosterText(names = []) {
  const list = names.filter((n) => typeof n === "string" && n !== "")
  if (list.length <= 1) return list[0] || ""
  if (list.length === 2) return `${list[0]} and ${list[1]}`
  if (list.length === 3) return `${list[0]}, ${list[1]} and ${list[2]}`
  return `${list[0]}, ${list[1]}, ${list[2]} and ${list.length - 3} others`
}

export function cardMetadata({ name, names = [], mic, elapsed }) {
  const who = rosterText(names)
  const micText = mic ? "mic on" : "mic off"
  return {
    title: `In ${name}`,
    artist: who ? `${who} · ${micText}` : micText,
    album: elapsed,
  }
}

export function callTitle({ name, elapsed, reconnecting, appName }) {
  const app = appName ? ` · ${appName}` : ""
  return reconnecting ? `● ↻ ${elapsed} ${name}${app}` : `● ${elapsed} ${name}${app}`
}

export function createMeetingMediaSession(env = {}) {
  const now = env.now || (() => Date.now())
  const setTick = env.setInterval || ((fn, ms) => setInterval(fn, ms))
  const clearTick = env.clearInterval || ((t) => clearInterval(t))
  const mediaSession = env.mediaSession || (() => null)
  const MediaMetadataCtor = env.MediaMetadata || (() => null)
  const nativeOwnsMedia = env.nativeOwnsMedia || (() => false)
  const getTitle = env.getTitle || (() => "")
  const setTitle = env.setTitle || (() => {})
  const appName = env.appName || (() => "")
  const readMic = env.readMic || (() => true)
  const readCamera = env.readCamera || (() => false)
  const toggleMic = env.toggleMic || (() => {})
  const toggleCamera = env.toggleCamera || (() => {})
  const hangup = env.hangup || (() => {})

  let active = false
  let tick = null
  let baseTitle = null
  let ownTitle = null
  let sessionOn = false
  let lastMeta = null
  let lastMetaAt = 0
  let snapshot = null

  function elapsedFor(state) {
    const started = Date.parse(state.startedAt || "")
    if (isNaN(started)) return formatElapsed(0)
    return formatElapsed((now() - started) / 1000)
  }

  // ── Tab title ──
  function writeTitle(text) {
    ownTitle = text
    try {
      setTitle(text)
    } catch (_) {
      /* no title to write */
    }
  }

  // LiveView rewrote the title (a live navigation, a page_title change):
  // that is the page's own title now, and ours goes back on top.
  function onTitleChanged() {
    if (safeTitle() === ownTitle) return
    if (active && snapshot && !snapshot.inCallRoom) render(snapshot, { metadata: false })
    else baseTitle = safeTitle()
  }

  function safeTitle() {
    try {
      return getTitle()
    } catch (_) {
      return ""
    }
  }

  function restoreTitle() {
    if (ownTitle == null) return
    const current = safeTitle()
    // Only put the page title back over our own text; LiveView may have
    // written a fresher one already.
    if (current === ownTitle && baseTitle != null) {
      try {
        setTitle(baseTitle)
      } catch (_) {
        /* nothing to restore into */
      }
    }
    ownTitle = null
  }

  // ── Media Session ──
  function session() {
    if (nativeOwnsMedia()) return null
    try {
      return mediaSession() || null
    } catch (_) {
      return null
    }
  }

  function handlerFor(action) {
    if (action === "togglemicrophone") return () => toggleMic()
    if (action === "togglecamera") return () => toggleCamera()
    return () => hangup()
  }

  function bindHandlers(ms) {
    if (typeof ms.setActionHandler !== "function") return
    for (const action of ACTIONS) {
      // Browsers throw on an action they do not know.
      try {
        ms.setActionHandler(action, handlerFor(action))
      } catch (_) {
        /* unsupported action */
      }
    }
  }

  function unbindHandlers(ms) {
    if (typeof ms.setActionHandler !== "function") return
    for (const action of ACTIONS) {
      try {
        ms.setActionHandler(action, null)
      } catch (_) {
        /* unsupported action */
      }
    }
  }

  function writeMetadata(ms, meta) {
    try {
      ms.metadata = MediaMetadataCtor(meta)
    } catch (_) {
      /* no MediaMetadata here */
    }
  }

  function syncDevices(ms, mic, camera) {
    try {
      if (typeof ms.setMicrophoneActive === "function") {
        const p = ms.setMicrophoneActive(mic)
        if (p && typeof p.catch === "function") p.catch(() => {})
      }
    } catch (_) {
      /* unsupported */
    }
    try {
      if (typeof ms.setCameraActive === "function") {
        const p = ms.setCameraActive(camera)
        if (p && typeof p.catch === "function") p.catch(() => {})
      }
    } catch (_) {
      /* unsupported */
    }
  }

  function clearSession() {
    if (!sessionOn) return
    sessionOn = false
    lastMeta = null
    lastMetaAt = 0
    let ms = null
    try {
      ms = mediaSession() || null
    } catch (_) {
      ms = null
    }
    if (!ms) return
    try {
      ms.metadata = null
    } catch (_) {
      /* read-only here */
    }
    unbindHandlers(ms)
  }

  function render(state, { metadata = true } = {}) {
    const elapsed = elapsedFor(state)

    if (state.inCallRoom) {
      restoreTitle()
    } else {
      // Anything that is not our own text is the page's own title.
      const current = safeTitle()
      if (ownTitle == null || current !== ownTitle) baseTitle = current
      const reconnecting = state.conn && state.conn.state === "reconnecting"
      const shown = reconnecting ? formatElapsed((now() - state.conn.since) / 1000) : elapsed
      writeTitle(callTitle({ name: state.name, elapsed: shown, reconnecting, appName: safeApp() }))
    }

    if (!metadata) return
    const ms = session()
    if (!ms) {
      clearSession()
      return
    }
    if (!sessionOn) {
      sessionOn = true
      bindHandlers(ms)
    }
    let mic = true
    let camera = false
    try {
      mic = !!readMic()
      camera = !!readCamera()
    } catch (_) {
      /* keep the defaults */
    }
    const meta = cardMetadata({ name: state.name, names: state.names || [], mic, elapsed })
    const changed =
      !lastMeta || lastMeta.title !== meta.title || lastMeta.artist !== meta.artist
    // Name / roster / mic changes go out at once (Mute on the lock screen
    // must read back); the elapsed time refreshes at most every 15s.
    if (changed || now() - lastMetaAt >= METADATA_REFRESH_MS) {
      writeMetadata(ms, meta)
      lastMeta = meta
      lastMetaAt = now()
    }
    syncDevices(ms, mic, camera)
  }

  function safeApp() {
    try {
      return appName() || ""
    } catch (_) {
      return ""
    }
  }

  function stop() {
    if (tick != null) clearTick(tick)
    tick = null
    active = false
    snapshot = null
    clearSession()
    restoreTitle()
  }

  return {
    // Presence state changed (mount, live navigation, reconnecting, leave).
    update(state) {
      const inCall = !!(state && state.inCall && !state.explicitLeave)
      if (!inCall) {
        if (active) stop()
        return
      }
      snapshot = state
      if (!active) {
        active = true
        tick = setTick(() => {
          if (active && snapshot) render(snapshot)
        }, TICK_MS)
      }
      render(state)
    },
    onTitleChanged,
    stop,
    _debug: () => ({ active, baseTitle, ownTitle, sessionOn, lastMeta }),
  }
}

// ── Browser wiring ───────────────────────────────────────────────────────

// The native call owns media inside the iOS app when its meetings plugin is
// there (the same check MeetingClient's native hand-off makes).
export function nativeCallOwnsMedia(win) {
  try {
    if (!win.Capacitor?.isNativePlatform?.()) return false
    const plugins = win.Capacitor.Plugins
    return !!(plugins && (plugins.BurrowMeetings || plugins.SuiteMeetings))
  } catch (_) {
    return false
  }
}

export function installMeetingMediaSession(win, doc, { toggleMic, toggleCamera, hangup }) {
  const titleEl = () => doc.querySelector && doc.querySelector("title")
  const room = () => win.__livekit_room || win.__livekitRoom || null
  const barButton = (sel) => doc.querySelector && doc.querySelector(`#meeting-top-bar ${sel}`)

  const controller = createMeetingMediaSession({
    mediaSession: () => (win.navigator && win.navigator.mediaSession) || null,
    MediaMetadata: (meta) =>
      typeof win.MediaMetadata === "function" ? new win.MediaMetadata(meta) : null,
    nativeOwnsMedia: () => nativeCallOwnsMedia(win),
    getTitle: () => doc.title,
    setTitle: (t) => {
      doc.title = t
    },
    appName: () => titleEl()?.dataset?.default || "",
    readMic: () => {
      const lp = room()?.localParticipant
      if (lp && typeof lp.isMicrophoneEnabled === "boolean") return lp.isMicrophoneEnabled
      const btn = barButton("[data-bar-mic]")
      return btn ? btn.getAttribute("aria-pressed") !== "true" : true
    },
    readCamera: () => {
      const lp = room()?.localParticipant
      if (lp && typeof lp.isCameraEnabled === "boolean") return lp.isCameraEnabled
      const btn = barButton("[data-bar-camera]")
      return btn ? btn.getAttribute("aria-pressed") === "true" : false
    },
    toggleMic,
    toggleCamera,
    hangup,
  })

  // LiveView writes `document.title` on a page_title change.
  const el = titleEl()
  if (el && typeof win.MutationObserver === "function") {
    try {
      new win.MutationObserver(() => controller.onTitleChanged()).observe(el, {
        childList: true,
        characterData: true,
        subtree: true,
      })
    } catch (_) {
      /* no observer: the 1s tick still rewrites ours */
    }
  }
  return controller
}
