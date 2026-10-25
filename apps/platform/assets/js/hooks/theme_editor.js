/**
 * ThemeEditor: the preview pane of /admin/themes (task 01a1557a-fe9b stage 2,
 * PlatformWeb.AdminThemesLive).
 *
 * The server pushes `theme-preview` with `{vars, mode}` on every change, once
 * per mode on show. This hook posts `{type: "burrow-theme", vars, mode}` to
 * each frame of that mode, with targetOrigin set to this page's own origin,
 * never "*": the frames are this app at /chat?theme_preview=1, and a frame
 * that has navigated anywhere else must not receive the draft. The receiver
 * is ./theme_preview_receiver.js.
 *
 * A frame that (re)loads gets the last payload for its mode, so Reload frames
 * and a mode switch do not wait for the next edit.
 *
 * It also scales the 1280x800 desktop frame to fit the pane, as the masters'
 * fitDesk does: the scale is a custom property on <html>, which LiveView never
 * patches, so a re-render cannot reset it.
 */

export const MESSAGE_TYPE = "burrow-theme"

export function previewMessage(payload) {
  return { type: MESSAGE_TYPE, vars: payload.vars, mode: payload.mode }
}

export function postPreview(frame, payload, origin) {
  const target = frame && frame.contentWindow
  if (!target) return false
  target.postMessage(previewMessage(payload), origin)
  return true
}

// The masters' fitDesk: pane width less padding, the phone and the gap,
// clamped to 0.35..1.
export function deskScale(paneWidth) {
  const avail = paneWidth - 36 - 375 - 18
  return Math.max(0.35, Math.min(1, avail / 1280))
}

const MODES = new Set(["dark", "light"])

const ThemeEditor = {
  mounted() {
    this.last = {}

    this.handleEvent("theme-preview", (payload) => {
      if (!payload || !MODES.has(payload.mode)) return
      this.last[payload.mode] = payload
      for (const frame of this.frames(payload.mode)) {
        postPreview(frame, payload, window.location.origin)
      }
    })

    this.onLoad = (event) => {
      const frame = event.target
      if (!frame || frame.tagName !== "IFRAME") return
      const payload = this.last[frame.dataset.mode]
      if (payload) postPreview(frame, payload, window.location.origin)
    }
    // `load` does not bubble; capture sees every frame's load.
    this.el.addEventListener("load", this.onLoad, true)

    this.fit = () =>
      document.documentElement.style.setProperty(
        "--theme-desk-scale",
        String(deskScale(this.el.clientWidth)),
      )
    window.addEventListener("resize", this.fit)
    this.fit()
  },

  updated() {
    this.fit()
  },

  destroyed() {
    this.el.removeEventListener("load", this.onLoad, true)
    window.removeEventListener("resize", this.fit)
    document.documentElement.style.removeProperty("--theme-desk-scale")
  },

  frames(mode) {
    return Array.from(this.el.querySelectorAll("iframe[data-mode]")).filter(
      (frame) => frame.dataset.mode === mode,
    )
  },
}

export default ThemeEditor
