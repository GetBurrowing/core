/**
 * Touch input for the `game_stream` canvas (task 01a0fe45 stage 2). Pure: the
 * hook hands in the rect, the clock, the scheduler and the sender, so vitest
 * drives it with fakes, as it does `game_stream_input.js`.
 *
 * Wire shape (`Platform.GameStream.Protocol`, "Touch"), on `input-events`:
 *
 *     {t: "touch", src: 0, id, ph, x, y}
 *
 * `id` is 0..9, `ph` is down | move | up | cancel, and `x`, `y` are in [0, 1],
 * normalised to the DISPLAYED VIDEO CONTENT: the decoded frame as drawn with
 * object-fit: contain, not the element's box. The router adds nothing but the
 * src: the host maps (peer, src 0) to a slot itself.
 *
 * devicePixelRatio never enters. `clientX`/`clientY` and
 * `getBoundingClientRect()` are both CSS pixels, so their ratio is the same
 * at DPR 1, 2 and 3; the host maps the normalised point to Godot pixels.
 *
 * Only `pointerType` touch and pen are forwarded. A mouse keeps the desktop's
 * click-to-capture keyboard.
 */

export const MAX_TOUCHES = 10
export const DEFAULT_SLOP_PX = 8
export const DEFAULT_MOVE_HZ = 60

const FORWARDED = ["touch", "pen"]

function clamp01(v) {
  return v < 0 ? 0 : v > 1 ? 1 : v
}

function posInt(v, fallback) {
  const n = Number(v)
  return Number.isFinite(n) && n >= 0 ? n : fallback
}

/**
 * The `touch` map of core's status and roster, as a plain shape. Anything
 * but `enabled: true` is off: a host without `game_stream_touch` (or an older
 * core that sends no map) gets the browser exactly as before.
 */
export function normalizeTouch(raw) {
  const t = raw && typeof raw === "object" ? raw : {}
  const hz = posInt(t.move_hz, DEFAULT_MOVE_HZ)
  return {
    enabled: t.enabled === true,
    slopPx: posInt(t.slop_px, DEFAULT_SLOP_PX),
    moveHz: hz > 0 ? hz : DEFAULT_MOVE_HZ,
  }
}

/**
 * The object-fit: contain content box of a `videoWidth` x `videoHeight` frame
 * inside `elRect` (any {left, top, width, height}, in CSS px): scaled by
 * min(w/vw, h/vh) and centred. Null while the frame has no size (no video
 * yet) or the element has none.
 */
export function contentRect(elRect, videoWidth, videoHeight) {
  if (!elRect || !(videoWidth > 0) || !(videoHeight > 0)) return null
  const w = elRect.width
  const h = elRect.height
  if (!(w > 0) || !(h > 0)) return null
  const scale = Math.min(w / videoWidth, h / videoHeight)
  const cw = videoWidth * scale
  const ch = videoHeight * scale
  return {
    left: elRect.left + (w - cw) / 2,
    top: elRect.top + (h - ch) / 2,
    width: cw,
    height: ch,
  }
}

/**
 * A client point against a content rect: `{x, y, inside}`, x and y clamped
 * to [0, 1]. `inside` is false for a point in a letterbox or pillarbox bar,
 * or anywhere off the frame.
 */
export function normalize(clientX, clientY, rect) {
  const rx = (clientX - rect.left) / rect.width
  const ry = (clientY - rect.top) / rect.height
  const inside = rx >= 0 && rx <= 1 && ry >= 0 && ry <= 1
  return { x: clamp01(rx), y: clamp01(ry), inside }
}

/**
 * The CSS aspect-ratio the well takes for a frame taller than 16:9 (a portrait
 * stream), or null for a 16:9-or-wider one, which keeps `aspect-video`.
 */
export function tallAspect(videoWidth, videoHeight) {
  if (!(videoWidth > 0) || !(videoHeight > 0)) return null
  return videoHeight * 16 > videoWidth * 9 ? `${videoWidth} / ${videoHeight}` : null
}

/**
 * pointerId to wire id: the smallest free id in 0..9, kept for the pointer's
 * lifetime. An 11th concurrent pointer gets none.
 */
export class TouchIds {
  constructor(max = MAX_TOUCHES) {
    this.max = max
    this.byPointer = new Map()
  }

  acquire(pointerId) {
    if (this.byPointer.has(pointerId)) return this.byPointer.get(pointerId)
    const used = new Set(this.byPointer.values())
    for (let id = 0; id < this.max; id++) {
      if (!used.has(id)) {
        this.byPointer.set(pointerId, id)
        return id
      }
    }
    return null
  }

  get(pointerId) {
    return this.byPointer.has(pointerId) ? this.byPointer.get(pointerId) : null
  }

  release(pointerId) {
    const id = this.get(pointerId)
    this.byPointer.delete(pointerId)
    return id
  }

  get size() {
    return this.byPointer.size
  }
}

/**
 * Turns pointer events into touch messages.
 *
 *   - `pointerdown` starts a touch only inside the content rect; a press in
 *     a bar sends nothing.
 *   - `pointermove` sends nothing until the pointer has travelled more than
 *     `slopPx` from its down, then at most one move per `1/moveHz` per id,
 *     coalesced to the latest position (a trailing move is scheduled so a
 *     drag that stops is not left behind). A touch dragged off the frame is
 *     clamped to its edge.
 *   - `pointerup` sends up; `pointercancel` and `lostpointercapture` send
 *     cancel. A tap that never left the slop lifts where it went down.
 *   - `releaseAll()` cancels every active touch.
 *
 * Each handler returns true when the event was this forwarder's (the hook
 * then preventDefaults it), false otherwise.
 *
 * Options: `isEnabled()`, `send(msg)`, `rect()` (the content rect now, or
 * null), `now()` in ms, `slopPx`, `moveHz`, and `schedule(fn, ms)` /
 * `unschedule(handle)` for the trailing move.
 */
export class TouchForwarder {
  constructor({ isEnabled, send, rect, now, slopPx, moveHz, schedule, unschedule } = {}) {
    this.isEnabled = isEnabled || (() => true)
    this.send = send || (() => {})
    this.rect = rect || (() => null)
    this.now = now || (() => Date.now())
    this.schedule = schedule || ((fn, ms) => setTimeout(fn, ms))
    this.unschedule = unschedule || (h => clearTimeout(h))
    this.configure({ slopPx, moveHz })
    this.ids = new TouchIds()
    // pointerId -> {id, startX, startY, moving, last: {x, y}, sentAt, pending, timer}
    this.active = new Map()
  }

  configure({ slopPx, moveHz } = {}) {
    this.slopPx = posInt(slopPx, DEFAULT_SLOP_PX)
    const hz = posInt(moveHz, DEFAULT_MOVE_HZ)
    this.moveHz = hz > 0 ? hz : DEFAULT_MOVE_HZ
  }

  get interval() {
    return 1000 / this.moveHz
  }

  forwarded(e) {
    return !!e && FORWARDED.includes(e.pointerType)
  }

  emit(t, ph, x, y) {
    this.send({ t: "touch", src: 0, id: t.id, ph, x, y })
  }

  pointerdown(e) {
    if (!this.forwarded(e) || !this.isEnabled()) return false
    if (this.active.has(e.pointerId)) return true
    const rect = this.rect()
    if (!rect) return false
    const p = normalize(e.clientX, e.clientY, rect)
    if (!p.inside) return false
    const id = this.ids.acquire(e.pointerId)
    if (id == null) return false
    const t = {
      id,
      startX: e.clientX,
      startY: e.clientY,
      moving: false,
      last: { x: p.x, y: p.y },
      sentAt: -Infinity,
      pending: null,
      timer: null,
    }
    this.active.set(e.pointerId, t)
    this.emit(t, "down", p.x, p.y)
    return true
  }

  pointermove(e) {
    const t = this.forwarded(e) ? this.active.get(e.pointerId) : null
    if (!t) return false
    if (!t.moving) {
      const dx = e.clientX - t.startX
      const dy = e.clientY - t.startY
      if (Math.hypot(dx, dy) <= this.slopPx) return true
      t.moving = true
    }
    const rect = this.rect()
    if (!rect) return true
    const p = normalize(e.clientX, e.clientY, rect)
    t.pending = { x: p.x, y: p.y }
    const wait = t.sentAt + this.interval - this.now()
    if (wait <= 0) this.flush(t)
    else if (t.timer == null) {
      t.timer = this.schedule(() => {
        t.timer = null
        if (this.active.get(e.pointerId) === t) this.flush(t)
      }, wait)
    }
    return true
  }

  flush(t) {
    if (!t.pending) return
    const { x, y } = t.pending
    t.pending = null
    t.last = { x, y }
    t.sentAt = this.now()
    this.emit(t, "move", x, y)
  }

  end(pointerId, ph, e) {
    const t = this.active.get(pointerId)
    if (!t) return false
    if (t.timer != null) this.unschedule(t.timer)
    t.timer = null
    this.active.delete(pointerId)
    this.ids.release(pointerId)
    let { x, y } = t.last
    if (ph === "up" && t.moving && e) {
      const rect = this.rect()
      if (rect) ({ x, y } = normalize(e.clientX, e.clientY, rect))
      else if (t.pending) ({ x, y } = t.pending)
    }
    this.emit(t, ph, x, y)
    return true
  }

  pointerup(e) {
    if (!this.forwarded(e)) return false
    return this.end(e.pointerId, "up", e)
  }

  pointercancel(e) {
    if (!this.forwarded(e)) return false
    return this.end(e.pointerId, "cancel", e)
  }

  lostpointercapture(e) {
    if (!this.forwarded(e)) return false
    return this.end(e.pointerId, "cancel", e)
  }

  /** Cancels every active touch (blur, hidden, a closed channel, a lost slot). */
  releaseAll() {
    const ids = Array.from(this.active.keys())
    for (const pointerId of ids) this.end(pointerId, "cancel", null)
    return ids.length
  }

  get count() {
    return this.active.size
  }
}
