// MeetingDevicePanel: the "Sound and video" panel (task 01a1f4c5 stage 2;
// design direction canvas 01a1f4c7).
//
// Mounted on the `contents` root `CallShell.call_controls/1` renders beside
// its row when `devices_id` is set. The server renders the frame (title,
// section labels, empty `phx-update="ignore"` lists); this hook renders the
// rows, because device ids and labels exist only in the browser and never
// reach the server. It pushes NO server events.
//
// What it owns:
//
//   * Triggers: every `[data-devices-for=<id>]` (the desktop carets, the
//     phone button). A click opens the popover or the sheet focused on that
//     trigger's section. `aria-expanded` is ours (ignored by LiveView).
//   * Rows: from `media_devices.listDevices`, the active one read from the
//     registered room. A pick calls `selectDevice`. Devices that appear or
//     disappear while the panel is open are inserted / removed IN PLACE:
//     the list never re-sorts under the cursor.
//   * Pick by proof: a live meter on the active mic row and on the focused
//     or hovered mic row only; the active camera row shows the PUBLISHED
//     track (no second capture), a focused / hovered camera row a short
//     160x90 preview (popover only: in the sheet, the active camera only).
//     Every stream this hook captured stops on close and on destroyed.
//   * SPEAKER: removed from the DOM when `supportsOutputSelection()` is
//     false. Removed, never disabled.
//   * The device-switched strap, on `meeting:device-fallback`, in the slot
//     above the controls row. UNTIMED (WCAG 2.2.1): cleared only by its
//     Dismiss button, by opening the panel, by the next active-device change
//     of that kind, or by unmuting. After a microphone fallback the mic
//     toggle's `aria-label` and `title` name the new device for the session.
//   * Keyboard: each section is a radiogroup with roving tabindex. Arrows
//     move, Enter / Space select, Esc closes (dismissable_overlay) and focus
//     returns to the trigger that opened the panel.

import * as MD from "../lib/media_devices.js"
import { openLayer } from "../lib/dismissable_overlay.js"
import { paintBars } from "./lib/ptt_waveform.js"

export const NOTICE_ROLE = "meeting-device-notice"
export const METER_MS = 90
export const MOVE_MS = 160
export const TEST_TONE_MS = 600
const SILENCE = 128
const METER_BARS = 5

const COPY = {
  audioinput: { empty: "No microphone found", blocked: "Microphone blocked by browser" },
  videoinput: { empty: "No camera found", blocked: "Camera blocked by browser" },
  audiooutput: { empty: "No speaker found", blocked: "No speaker found" },
}

// The blocked / switch-failed glyph: `text-error` on an aria-hidden icon,
// next to base-content text (canvas palette: error icon plus base-content).
const ERROR_ICON_CLASS = "hero-exclamation-circle mt-0.5 size-4 shrink-0 text-error"

const PERMISSION = { audioinput: "microphone", videoinput: "camera" }

// Characters per label before the middle is cut, per kind (the meter and
// the thumbnail take different widths of the 320px popover).
export const TRUNCATE_AT = { audioinput: 26, videoinput: 22, audiooutput: 30 }

const PUBLISHED_SOURCE = { audioinput: "microphone", videoinput: "camera" }

export function noticeText(fromLabel, toLabel) {
  const from = fromLabel || "Your device"
  return `${from} disconnected. Now using ${toLabel}.`
}

export function switchFailedText(label) {
  return `Couldn't switch to ${label || "that device"}.`
}

function el(doc, tag, attrs = {}, children = []) {
  const node = doc.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) {
    if (v === false || v === null || v === undefined) continue
    node.setAttribute(k, v === true ? "" : String(v))
  }
  for (const c of children) {
    node.appendChild(typeof c === "string" ? doc.createTextNode(c) : c)
  }
  return node
}

function elementChildren(node) {
  return Array.from((node && node.childNodes) || []).filter((c) => c && c.nodeType === 1)
}

function detach(node) {
  if (node && node.parentNode) node.parentNode.removeChild(node)
}

function prefersReducedMotion(win) {
  try {
    if (!win || typeof win.matchMedia !== "function") return true
    return win.matchMedia("(prefers-reduced-motion: reduce)").matches === true
  } catch (_e) {
    return true
  }
}

function stopStream(stream) {
  if (!stream || typeof stream.getTracks !== "function") return
  for (const t of stream.getTracks()) {
    try {
      t.stop()
    } catch (_e) {}
  }
}

const MeetingDevicePanel = {
  mounted() {
    this._win = typeof window !== "undefined" ? window : null
    this._docRef = typeof document !== "undefined" ? document : null
    this._open = null // {container, panel, opener, layer}
    this._previews = new Map() // key -> {stream, owned, ctx?, timer?, node}
    this._hover = new Map() // kind -> deviceId
    this._micName = null
    this._notice = null
    this._audioCtx = null
    this._outputSupported = MD.supportsOutputSelection()

    if (!this._outputSupported) {
      for (const section of this.el.querySelectorAll('[data-device-section="audiooutput"]')) {
        detach(section)
      }
    }

    // Delegated, not bound per trigger: the triggers live in the controls
    // row OUTSIDE this ignored root, and LiveView replaces them whenever
    // that row re-renders (joining, leaving, native hand-off), which would
    // strand a listener bound at mount.
    this._onTrigger = (event) => {
      const t = event.target
      const trigger =
        t && typeof t.closest === "function" ? t.closest(`[data-devices-for="${this.el.id}"]`) : null
      if (!trigger) return
      if (event.preventDefault) event.preventDefault()
      this.toggle(trigger)
    }
    const doc0 = this._doc()
    if (doc0 && typeof doc0.addEventListener === "function") {
      doc0.addEventListener("click", this._onTrigger)
    }

    this._bindPanel(this._panel("popover"))
    this._bindPanel(this._panel("sheet"))

    this._onDevicesChanged = (e) => {
      const kind = e && e.detail && e.detail.kind
      if (this._open && kind) this._renderSection(kind)
    }
    this._onActiveDevice = (e) => {
      const d = (e && e.detail) || {}
      if (this._notice && this._notice.kind === d.kind && this._notice.armed) this.clearNotice()
      if (d.kind === "audioinput" && this._micName && d.deviceId) {
        this._micName = MD.labelFor(d.deviceId) || this._micName
        this._applyMicName()
      }
      if (this._open && d.kind) this._renderSection(d.kind)
    }
    this._onFallback = (e) => this.showNotice((e && e.detail) || {})

    const w = this._win
    if (w && typeof w.addEventListener === "function") {
      w.addEventListener(MD.DEVICES_CHANGED_EVENT, this._onDevicesChanged)
      w.addEventListener(MD.ACTIVE_DEVICE_EVENT, this._onActiveDevice)
      w.addEventListener(MD.DEVICE_FALLBACK_EVENT, this._onFallback)
    }
    this._observeMicToggle()
  },

  destroyed() {
    this._destroyed = true
    const doc0 = this._doc()
    if (doc0 && typeof doc0.removeEventListener === "function") {
      doc0.removeEventListener("click", this._onTrigger)
    }
    const w = this._win
    if (w && typeof w.removeEventListener === "function") {
      w.removeEventListener(MD.DEVICES_CHANGED_EVENT, this._onDevicesChanged)
      w.removeEventListener(MD.ACTIVE_DEVICE_EVENT, this._onActiveDevice)
      w.removeEventListener(MD.DEVICE_FALLBACK_EVENT, this._onFallback)
    }
    if (this._micObserver) this._micObserver.disconnect()
    if (this._open && this._open.layer) this._open.layer.release()
    this._teardown()
    this._stopTone()
  },

  // ── open / close ──────────────────────────────────────────────────

  _doc() {
    return this._docRef || this.el.ownerDocument
  },

  _triggerList() {
    const doc = this._doc()
    if (!doc || typeof doc.querySelectorAll !== "function") return []
    return Array.from(doc.querySelectorAll(`[data-devices-for="${this.el.id}"]`))
  },

  _panel(container) {
    return this.el.querySelector(`[data-role="meeting-device-panel"][data-container="${container}"]`)
  },

  _bindPanel(panel) {
    if (!panel) return
    panel.addEventListener("click", (event) => this._onPanelClick(event))
    panel.addEventListener("keydown", (event) => this._onPanelKey(event))
  },

  isOpen() {
    return !!this._open
  },

  toggle(trigger) {
    if (this._open && this._open.opener === trigger) {
      this.close()
      return Promise.resolve()
    }
    const container = trigger.getAttribute("data-devices-container") || "popover"
    const section = trigger.getAttribute("data-devices-section") || "audioinput"
    return this.open({ container, section, opener: trigger })
  },

  async open({ container = "popover", section = "audioinput", opener = null } = {}) {
    if (this._open) this.close()
    const panel = this._panel(container)
    if (!panel) return
    this.clearNotice()
    this._open = { container, panel, opener, layer: null }
    if (opener) opener.setAttribute("aria-expanded", "true")
    panel.removeAttribute("hidden")
    if (container === "popover") this._place(panel, opener)

    await this._renderAll()
    if (!this._open || this._open.panel !== panel) return

    const focusTo = this._focusTarget(panel, section)
    const card = container === "sheet" ? panel.querySelector("[data-device-card]") : panel
    this._open.layer = openLayer({
      el: panel,
      onClose: () => this._teardown(),
      returnFocusTo: opener,
      closeControl: focusTo,
      swipeTarget: container === "sheet" ? card : undefined,
    })

    this._onOutside = (event) => {
      if (!this._open) return
      const t = event.target
      const inside =
        t &&
        ((card && card.contains && card.contains(t)) ||
          this._triggerList().some((tr) => tr === t || (tr.contains && tr.contains(t))))
      if (!inside) this.close()
    }
    const doc = this._doc()
    if (doc && typeof doc.addEventListener === "function") {
      doc.addEventListener("pointerdown", this._onOutside, true)
    }
  },

  close() {
    if (!this._open) return
    if (this._open.layer) this._open.layer.close()
    else this._teardown()
  },

  // Runs exactly once per open, however the panel closes.
  _teardown() {
    const open = this._open
    this._open = null
    const doc = this._doc()
    if (this._onOutside && doc && typeof doc.removeEventListener === "function") {
      doc.removeEventListener("pointerdown", this._onOutside, true)
    }
    this._onOutside = null
    this._stopAllPreviews()
    this._hover.clear()
    if (!open) return
    open.panel.setAttribute("hidden", "")
    if (open.opener) open.opener.setAttribute("aria-expanded", "false")
  },

  _place(panel, opener) {
    const w = this._win
    if (!opener || typeof opener.getBoundingClientRect !== "function" || !w) return
    const rect = opener.getBoundingClientRect()
    const width = panel.offsetWidth || 320
    const vw = w.innerWidth || 0
    const vh = w.innerHeight || 0
    const left = Math.max(8, Math.min(rect.left - 8, vw - width - 8))
    panel.style.left = `${Math.round(left)}px`
    panel.style.bottom = `${Math.round(vh - rect.top + 8)}px`
  },

  _focusTarget(panel, kind) {
    const list = panel.querySelector(`[data-device-list="${kind}"]`)
    const rows = list ? this._rows(list) : []
    const target =
      rows.find((r) => r.getAttribute("aria-checked") === "true") ||
      rows[0] ||
      panel.querySelector("[data-device-close]") ||
      panel
    return target
  },

  // ── rendering ─────────────────────────────────────────────────────

  _sections() {
    if (!this._open) return []
    return Array.from(this._open.panel.querySelectorAll("[data-device-list]")).map((l) =>
      l.getAttribute("data-device-list"),
    )
  },

  async _renderAll() {
    await Promise.all(this._sections().map((kind) => this._renderSection(kind)))
  },

  _room() {
    return MD.activeRoom("meeting") || MD.activeRoom()
  },

  _activeId(kind, devices) {
    const room = this._room()
    const fromRoom = room && typeof room.getActiveDevice === "function" ? room.getActiveDevice(kind) : null
    if (fromRoom && devices.some((d) => d.deviceId === fromRoom)) return fromRoom
    const { device } = MD.resolvePreferred(kind, devices)
    return device ? device.deviceId : null
  },

  _rows(list) {
    return elementChildren(list).filter((c) => c.getAttribute("role") === "radio")
  },

  async _renderSection(kind) {
    const open = this._open
    if (!open) return
    const list = open.panel.querySelector(`[data-device-list="${kind}"]`)
    if (!list) return
    const devices = await MD.listDevices(kind)
    if (this._open !== open) return
    const status = open.panel.querySelector(`[data-device-status="${kind}"]`)

    if (devices.length === 0) {
      const blocked = await this._permissionDenied(kind)
      if (this._open !== open) return
      for (const row of this._rows(list)) this._removeRow(row, { immediate: true })
      this._setStatus(status, blocked ? COPY[kind].blocked : COPY[kind].empty, blocked ? "blocked" : "empty")
      return
    }
    if (status && status.getAttribute("data-state") !== "failed") this._setStatus(status, null)

    const ids = new Set(devices.map((d) => d.deviceId))
    const existing = new Map()
    for (const row of this._rows(list)) {
      if (row.getAttribute("data-leaving") === "true") continue
      const id = row.getAttribute("data-device-id")
      if (ids.has(id)) existing.set(id, row)
      else this._removeRow(row)
    }

    // Insert new devices next to their enumerated neighbour; never move an
    // existing row.
    devices.forEach((device, i) => {
      if (existing.has(device.deviceId)) return
      const row = this._buildRow(kind, device, open.container)
      let before = null
      for (let j = i + 1; j < devices.length; j++) {
        const next = existing.get(devices[j].deviceId)
        if (next) {
          before = next
          break
        }
      }
      list.insertBefore(row, before)
      existing.set(device.deviceId, row)
    })

    const active = this._activeId(kind, devices)
    this._markActive(list, active)
    this._refreshActivePreview(kind, active)
  },

  async _permissionDenied(kind) {
    const name = PERMISSION[kind]
    const perms = typeof navigator !== "undefined" && navigator.permissions
    if (!name || !perms || typeof perms.query !== "function") return false
    try {
      const state = await perms.query({ name })
      return !!state && state.state === "denied"
    } catch (_e) {
      return false
    }
  },

  _setStatus(status, text, state = null) {
    if (!status) return
    const doc = this._doc()
    if (!text) {
      status.replaceChildren()
      status.setAttribute("hidden", "")
      status.removeAttribute("data-state")
      return
    }
    const children = []
    if (state === "blocked" || state === "failed") {
      children.push(
        el(doc, "span", { class: ERROR_ICON_CLASS, "aria-hidden": "true" }),
      )
    }
    children.push(
      el(doc, "span", { class: state === "empty" ? "text-subtle" : "text-base-content" }, [text]),
    )
    status.replaceChildren(...children)
    status.setAttribute("data-state", state || "")
    status.removeAttribute("hidden")
  },

  _buildRow(kind, device, container) {
    const doc = this._doc()
    const sheet = container === "sheet"
    const full = device.label
    const shown = sheet ? full : MD.truncateMiddle(full, TRUNCATE_AT[kind] || 26)
    const tags = []
    if (device.virtual) tags.push("virtual")
    if (device.default) tags.push("default")

    const row = el(doc, "div", {
      role: "radio",
      "aria-checked": "false",
      tabindex: "-1",
      "data-device-id": device.deviceId,
      "data-device-kind": kind,
      "data-role": "meeting-device-row",
      title: shown !== full ? full : null,
      "aria-label": full,
      class:
        "flex min-h-9 cursor-pointer items-center gap-2 rounded-field px-2 py-1.5 text-sm text-base-content outline-offset-[-2px] pointer-coarse:min-h-11 pointer-fine:hover:bg-base-200 focus-visible:bg-base-200 motion-safe:transition-opacity motion-safe:duration-160 starting:opacity-0",
    })
    row.appendChild(
      el(doc, "span", {
        "data-device-check": "",
        class: "size-4 shrink-0",
        "aria-hidden": "true",
      }),
    )
    row.appendChild(
      el(
        doc,
        "span",
        {
          "data-device-label": "",
          class: sheet ? "min-w-0 flex-1 line-clamp-2 break-words" : "min-w-0 flex-1 truncate",
        },
        [shown],
      ),
    )
    for (const tag of tags) {
      row.appendChild(
        el(doc, "span", { "data-device-tag": tag, class: "shrink-0 text-xs text-subtle" }, [tag]),
      )
    }
    row.appendChild(el(doc, "span", { "data-device-proof": "", class: "shrink-0" }))

    row.addEventListener("mouseenter", () => this._probe(kind, device.deviceId, "hover"))
    row.addEventListener("mouseleave", () => this._unprobe(kind, device.deviceId, "hover"))
    row.addEventListener("focus", () => this._probe(kind, device.deviceId, "focus"))
    row.addEventListener("blur", () => this._unprobe(kind, device.deviceId, "focus"))
    return row
  },

  _removeRow(row, { immediate = false } = {}) {
    const kind = row.getAttribute("data-device-kind")
    const id = row.getAttribute("data-device-id")
    this._stopPreview(`${kind}:${id}`)
    if (immediate || prefersReducedMotion(this._win)) {
      detach(row)
      return
    }
    row.setAttribute("data-leaving", "true")
    row.setAttribute("aria-hidden", "true")
    row.style.opacity = "0"
    setTimeout(() => detach(row), MOVE_MS)
  },

  _markActive(list, activeId) {
    const rows = this._rows(list).filter((r) => r.getAttribute("data-leaving") !== "true")
    const focused = rows.find((r) => r.getAttribute("tabindex") === "0")
    let any = false
    for (const row of rows) {
      const on = row.getAttribute("data-device-id") === activeId
      any = any || on
      row.setAttribute("aria-checked", on ? "true" : "false")
      const label = row.querySelector("[data-device-label]")
      if (label) {
        const cls = label.getAttribute("class") || ""
        const base = cls.replace(/\s*font-semibold\b/g, "")
        label.setAttribute("class", on ? `${base} font-semibold` : base)
      }
      const check = row.querySelector("[data-device-check]")
      if (check) check.setAttribute("class", on ? "hero-check size-4 shrink-0" : "size-4 shrink-0")
    }
    // Roving tabindex: keep a row the person is on; else the checked row.
    const doc = this._doc()
    const keep = focused && doc && doc.activeElement === focused ? focused : null
    const tabStop = keep || rows.find((r) => r.getAttribute("aria-checked") === "true") || rows[0]
    for (const row of rows) row.setAttribute("tabindex", row === tabStop ? "0" : "-1")
    return any
  },

  // ── selection & keyboard ──────────────────────────────────────────

  _onPanelClick(event) {
    const t = event.target
    if (!t || typeof t.closest !== "function") return
    if (t.closest("[data-device-close]") || t.closest("[data-device-backdrop]")) {
      this.close()
      return
    }
    if (t.closest("[data-device-test-sound]")) {
      this.testSound()
      return
    }
    const row = t.closest('[role="radio"]')
    if (row) this.select(row)
  },

  _onPanelKey(event) {
    const t = event.target
    const row = t && typeof t.closest === "function" ? t.closest('[role="radio"]') : null
    if (!row) return
    const list = row.parentNode
    const rows = this._rows(list).filter((r) => r.getAttribute("data-leaving") !== "true")
    const i = rows.indexOf(row)
    let next = null
    switch (event.key) {
      case "ArrowDown":
      case "ArrowRight":
        next = rows[(i + 1) % rows.length]
        break
      case "ArrowUp":
      case "ArrowLeft":
        next = rows[(i - 1 + rows.length) % rows.length]
        break
      case "Home":
        next = rows[0]
        break
      case "End":
        next = rows[rows.length - 1]
        break
      case "Enter":
      case " ":
      case "Spacebar":
        if (event.preventDefault) event.preventDefault()
        this.select(row)
        return
      default:
        return
    }
    if (event.preventDefault) event.preventDefault()
    if (!next) return
    for (const r of rows) r.setAttribute("tabindex", r === next ? "0" : "-1")
    next.focus()
  },

  async select(row) {
    const kind = row.getAttribute("data-device-kind")
    const deviceId = row.getAttribute("data-device-id")
    const open = this._open
    const status = open && open.panel.querySelector(`[data-device-status="${kind}"]`)
    const result = await MD.selectDevice(kind, deviceId, { room: this._room() })
    if (!this._open || this._open !== open) return result
    const list = open.panel.querySelector(`[data-device-list="${kind}"]`)
    if (result && result.ok) {
      this._setStatus(status, null)
      if (list) this._markActive(list, deviceId)
      this._refreshActivePreview(kind, deviceId)
    } else {
      this._setStatus(status, switchFailedText(MD.labelFor(deviceId)), "failed")
      if (list) this._markActive(list, result && result.deviceId)
    }
    return result
  },

  // ── pick by proof ─────────────────────────────────────────────────

  _publishedTrack(kind) {
    const room = this._room()
    const lp = room && room.localParticipant
    const source = PUBLISHED_SOURCE[kind]
    if (!lp || !source || typeof lp.getTrackPublication !== "function") return null
    const pub = lp.getTrackPublication(source)
    const mst = pub && pub.track && pub.track.mediaStreamTrack
    return mst && mst.readyState !== "ended" ? mst : null
  },

  _refreshActivePreview(kind, activeId) {
    if (!this._open || kind === "audiooutput") return
    // Drop any active preview that is no longer the active device.
    for (const [key, p] of this._previews) {
      if (p.kind === kind && p.reason === "active" && p.deviceId !== activeId) this._stopPreview(key)
    }
    if (!activeId) return
    const key = `${kind}:${activeId}`
    if (this._previews.has(key)) return
    const published = typeof MediaStream === "function" ? this._publishedTrack(kind) : null
    if (kind === "videoinput") {
      // The active camera's thumbnail is the published track, never a
      // second capture. Camera off: no thumbnail.
      if (published) this._attachPreview(kind, activeId, new MediaStream([published]), false, "active")
      return
    }
    if (published) {
      this._attachPreview(kind, activeId, new MediaStream([published]), false, "active")
    } else {
      this._capture(kind, activeId, "active")
    }
  },

  _probe(kind, deviceId, why) {
    if (!this._open || kind === "audiooutput") return
    if (why === "hover") this._hover.set(kind, deviceId)
    const key = `${kind}:${deviceId}`
    if (this._previews.has(key)) return
    // Below `sm` (the sheet) only the active camera gets a thumbnail.
    if (kind === "videoinput" && this._open.container === "sheet") return
    // One probe per kind at a time.
    for (const [k, p] of this._previews) {
      if (p.kind === kind && p.reason === "probe") this._stopPreview(k)
    }
    this._capture(kind, deviceId, "probe")
  },

  _unprobe(kind, deviceId, why) {
    if (why === "hover" && this._hover.get(kind) === deviceId) this._hover.delete(kind)
    const key = `${kind}:${deviceId}`
    const p = this._previews.get(key)
    if (!p || p.reason !== "probe") return
    const doc = this._doc()
    const row = this._rowFor(kind, deviceId)
    const stillFocused = why === "hover" && row && doc && doc.activeElement === row
    const stillHovered = why === "focus" && this._hover.get(kind) === deviceId
    if (!stillFocused && !stillHovered) this._stopPreview(key)
  },

  _rowFor(kind, deviceId) {
    if (!this._open) return null
    const list = this._open.panel.querySelector(`[data-device-list="${kind}"]`)
    return list ? this._rows(list).find((r) => r.getAttribute("data-device-id") === deviceId) : null
  },

  async _capture(kind, deviceId, reason) {
    const md = typeof navigator !== "undefined" && navigator.mediaDevices
    if (!md || typeof md.getUserMedia !== "function") return
    const key = `${kind}:${deviceId}`
    const open = this._open
    // Reserve the slot so a second probe of the same row does not double up.
    this._previews.set(key, { kind, deviceId, reason, stream: null, owned: true, pending: true })
    const constraints =
      kind === "audioinput"
        ? { audio: { deviceId: { exact: deviceId } } }
        : { video: { deviceId: { exact: deviceId }, width: 160, height: 90 } }
    let stream
    try {
      stream = await md.getUserMedia(constraints)
    } catch (_e) {
      this._previews.delete(key)
      return
    }
    const slot = this._previews.get(key)
    if (!slot || this._open !== open || !this._open) {
      // Closed (or the probe ended) while the capture was pending.
      stopStream(stream)
      if (slot && slot.pending) this._previews.delete(key)
      return
    }
    this._previews.delete(key)
    this._attachPreview(kind, deviceId, stream, true, reason)
  },

  _attachPreview(kind, deviceId, stream, owned, reason) {
    const key = `${kind}:${deviceId}`
    const row = this._rowFor(kind, deviceId)
    const proof = row && row.querySelector("[data-device-proof]")
    if (!proof) {
      if (owned) stopStream(stream)
      return
    }
    const doc = this._doc()
    const entry = { kind, deviceId, reason, stream, owned, node: null, timer: null, src: null }
    if (kind === "videoinput") {
      const video = el(doc, "video", {
        "data-device-thumb": "",
        muted: true,
        playsinline: true,
        autoplay: true,
        "aria-hidden": "true",
        class: "block h-9 w-16 rounded-field border border-edge bg-base-200 object-cover",
      })
      video.muted = true
      video.srcObject = stream
      if (typeof video.play === "function") {
        try {
          const p = video.play()
          if (p && typeof p.catch === "function") p.catch(() => {})
        } catch (_e) {}
      }
      proof.appendChild(video)
      entry.node = video
    } else {
      const bars = []
      for (let i = 0; i < METER_BARS; i++) {
        bars.push(
          el(doc, "i", {
            "data-meter-bar": "",
            class: "block h-3 w-1 origin-bottom rounded-sm bg-info",
          }),
        )
      }
      const meter = el(
        doc,
        "span",
        {
          "data-device-meter": "",
          "aria-hidden": "true",
          class: "flex h-4 items-end gap-0.5 rounded-sm bg-base-200 px-1 py-0.5",
        },
        bars,
      )
      proof.appendChild(meter)
      entry.node = meter
      const ctx = this._ctx()
      if (ctx) {
        try {
          const src = ctx.createMediaStreamSource(stream)
          const analyser = ctx.createAnalyser()
          analyser.fftSize = 256
          src.connect(analyser)
          const data = new Uint8Array(analyser.fftSize)
          entry.src = src
          entry.timer = setInterval(() => {
            analyser.getByteTimeDomainData(data)
            let sum = 0
            for (let i = 0; i < data.length; i++) {
              const v = (data[i] - SILENCE) / SILENCE
              sum += v * v
            }
            paintBars(bars, Math.sqrt(sum / data.length))
          }, METER_MS)
        } catch (_e) {}
      }
    }
    this._previews.set(key, entry)
  },

  _ctx() {
    if (this._audioCtx) return this._audioCtx
    const w = this._win
    const Ctx = w && (w.AudioContext || w.webkitAudioContext)
    if (!Ctx) return null
    try {
      this._audioCtx = new Ctx()
    } catch (_e) {
      this._audioCtx = null
    }
    return this._audioCtx
  },

  _stopPreview(key) {
    const p = this._previews.get(key)
    if (!p) return
    this._previews.delete(key)
    if (p.timer) clearInterval(p.timer)
    if (p.src && typeof p.src.disconnect === "function") {
      try {
        p.src.disconnect()
      } catch (_e) {}
    }
    if (p.node) {
      if (p.node.srcObject) p.node.srcObject = null
      detach(p.node)
    }
    // Never stop a PUBLISHED track: that would end the person's own mic or
    // camera in the call.
    if (p.owned) stopStream(p.stream)
  },

  _stopAllPreviews() {
    for (const key of Array.from(this._previews.keys())) this._stopPreview(key)
    // A capture still pending resolves into _capture's closed branch and is
    // stopped there.
    if (this._audioCtx) {
      try {
        this._audioCtx.close()
      } catch (_e) {}
      this._audioCtx = null
    }
  },

  // ── Test sound ────────────────────────────────────────────────────

  async testSound() {
    if (this._tone) return
    const w = this._win
    const Ctx = w && (w.AudioContext || w.webkitAudioContext)
    const doc = this._doc()
    if (!Ctx || !doc) return
    const button = this._open && this._open.panel.querySelector("[data-device-test-sound]")
    const room = this._room()
    const sink =
      (room && typeof room.getActiveDevice === "function" && room.getActiveDevice("audiooutput")) ||
      (MD.resolvePreferred("audiooutput").device || {}).deviceId ||
      null
    let ctx
    try {
      ctx = new Ctx()
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      gain.gain.value = 0.2
      const dest = ctx.createMediaStreamDestination()
      osc.frequency.value = 660
      osc.connect(gain)
      gain.connect(dest)
      const audio = doc.createElement("audio")
      audio.srcObject = dest.stream
      if (sink && typeof audio.setSinkId === "function") await audio.setSinkId(sink)
      this._tone = { ctx, osc, audio, button }
      if (button) button.setAttribute("data-playing", "true")
      osc.start()
      const p = audio.play()
      if (p && typeof p.catch === "function") p.catch(() => {})
      this._toneTimer = setTimeout(() => this._stopTone(), TEST_TONE_MS)
    } catch (_e) {
      this._stopTone()
      if (ctx && !this._tone) {
        try {
          ctx.close()
        } catch (_e2) {}
      }
    }
  },

  _stopTone() {
    if (this._toneTimer) clearTimeout(this._toneTimer)
    this._toneTimer = null
    const t = this._tone
    this._tone = null
    if (!t) return
    try {
      t.osc.stop()
    } catch (_e) {}
    try {
      t.audio.pause()
      t.audio.srcObject = null
    } catch (_e) {}
    try {
      t.ctx.close()
    } catch (_e) {}
    if (t.button) t.button.removeAttribute("data-playing")
  },

  // ── the device-switched strap ─────────────────────────────────────

  _slot() {
    return this.el.querySelector('[data-role="meeting-device-notice-slot"]')
  },

  showNotice({ kind, fromLabel, toLabel } = {}) {
    const slot = this._slot()
    if (!slot || !toLabel) return
    const doc = this._doc()
    const strap = el(
      doc,
      "div",
      {
        "data-role": NOTICE_ROLE,
        "data-kind": kind || "",
        class:
          "mx-2 my-1 flex items-center gap-2 rounded-field bg-info px-3 py-1.5 text-sm text-info-content",
      },
      [
        el(doc, "span", {
          class: "hero-information-circle size-4 shrink-0",
          "aria-hidden": "true",
        }),
        el(doc, "span", { "data-notice-text": "", class: "min-w-0 flex-1 break-words" }, [
          noticeText(fromLabel, toLabel),
        ]),
        el(
          doc,
          "button",
          {
            type: "button",
            "data-notice-change": "",
            class:
              "btn btn-ghost btn-xs pointer-coarse:min-h-11 shrink-0 font-semibold text-info-content underline",
          },
          ["Change"],
        ),
        el(
          doc,
          "button",
          {
            type: "button",
            "data-notice-dismiss": "",
            "aria-label": "Dismiss",
            class:
              "btn btn-ghost btn-xs btn-square pointer-coarse:min-h-11 pointer-coarse:min-w-11 shrink-0 text-info-content",
          },
          [el(doc, "span", { class: "hero-x-mark size-4", "aria-hidden": "true" })],
        ),
      ],
    )
    strap.querySelector("[data-notice-dismiss]").addEventListener("click", () => this.clearNotice())
    strap.querySelector("[data-notice-change]").addEventListener("click", () => {
      const opener = this._openerFor(kind)
      this.open({
        container: opener ? opener.getAttribute("data-devices-container") : "sheet",
        section: kind || "audioinput",
        opener,
      })
    })
    slot.replaceChildren(strap)
    // The fallback's own active-device event fires BEFORE this one; only a
    // LATER change of the same kind clears the strap.
    this._notice = { kind, strap, armed: true }

    if (kind === "audioinput") {
      this._micName = toLabel
      this._applyMicName()
    }
  },

  clearNotice() {
    const slot = this._slot()
    if (slot) slot.replaceChildren()
    this._notice = null
  },

  _openerFor(kind) {
    const w = this._win
    let desktop = false
    try {
      desktop = !!(w && w.matchMedia && w.matchMedia("(min-width: 640px) and (pointer: fine)").matches)
    } catch (_e) {}
    const container = desktop ? "popover" : "sheet"
    const triggers = this._triggerList().filter((t) => this._visible(t))
    return (
      triggers.find(
        (t) =>
          t.getAttribute("data-devices-container") === container &&
          (container === "sheet" || t.getAttribute("data-devices-section") === kind),
      ) ||
      triggers.find((t) => t.getAttribute("data-devices-container") === container) ||
      triggers[0] ||
      null
    )
  },

  _visible(node) {
    if (!node) return false
    if (typeof node.getClientRects !== "function") return true
    return node.getClientRects().length > 0
  },

  // ── the mic toggle carries the device name after a fallback ───────

  _micToggle() {
    const doc = this._doc()
    return doc && typeof doc.querySelector === "function"
      ? doc.querySelector(`[data-devices-toggle="${this.el.id}"]`)
      : null
  },

  _applyMicName() {
    const toggle = this._micToggle()
    if (!toggle || !this._micName) return
    const suffix = `, ${this._micName}`
    const label = toggle.getAttribute("aria-label") || ""
    const base = label.includes(", ") ? label.slice(0, label.indexOf(", ")) : label
    if (label !== base + suffix) toggle.setAttribute("aria-label", base + suffix)
    const title = `Microphone: ${this._micName}`
    if (toggle.getAttribute("title") !== title) toggle.setAttribute("title", title)
  },

  _observeMicToggle() {
    const toggle = this._micToggle()
    const w = this._win
    const MO = w && w.MutationObserver
    if (!toggle || !MO) return
    let wasOn = toggle.getAttribute("data-on")
    this._micObserver = new MO(() => {
      const on = toggle.getAttribute("data-on")
      // Unmuting clears a microphone strap.
      if (wasOn === "false" && on === "true" && this._notice && this._notice.kind === "audioinput") {
        this.clearNotice()
      }
      wasOn = on
      // A LiveView patch rewrites aria-label on every mute; put the name back.
      this._applyMicName()
    })
    this._micObserver.observe(toggle, { attributes: true, attributeFilter: ["aria-label", "data-on"] })
  },
}

export default MeetingDevicePanel
