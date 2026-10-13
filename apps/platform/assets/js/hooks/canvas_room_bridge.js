/**
 * CanvasRoomBridge — relays a sealed frame's `window.suite` (the bridge
 * script PrototypeController injects, priv/prototype/suite.js) to its canvas
 * room over this page's LiveView socket (task 01a1316b-84fa stage 2).
 *
 * Mounted on the element that CONTAINS the iframe, with `data-canvas-id`
 * and `data-node-id` (`Platform.Chat.CanvasRoom.frame_attrs/2`).
 *
 * Trust rules, in order:
 *
 *   1. A window `message` event is accepted only when `event.source` IS this
 *      iframe's `contentWindow`. Identity, never origin: the sandboxed frame's
 *      origin is the string "null", which every other opaque frame shares.
 *   2. It must then pass a fixed schema (`validFrameMessage/1`): a known
 *      type, an op type in the room's op set, string keys of at most 128
 *      bytes, and at most 64 KB serialised.
 *   3. The canvas id and node id sent to the server come from this element's
 *      data attributes, NEVER from the message. The frame cannot name a room;
 *      the room is whichever iframe spoke. The server reads the actor from
 *      its own session, never from params.
 *
 * Server pushes `canvas_room:<canvas_id>:<node_id>:{snapshot,diff,presence,
 * ephemeral}` are posted to `contentWindow` with target "*", which is
 * required because the frame's origin is opaque.
 *
 * HONEST LIMIT: CSP3 has no `navigate-to`, so a bundle can navigate its own
 * frame to another page, and that page then receives this room's messages.
 * That is the trust boundary the hosting plan already states: a bundle's
 * author can exfiltrate whatever the bundle can see.
 *
 * Joins on every iframe `load` and on every `hello` (the bridge's start-up
 * and seq-gap resync). Leaves on destroyed.
 */

export const OP_TYPES = new Set([
  "state.set",
  "state.increment",
  "collection.add",
  "collection.update",
  "collection.remove",
])
const FRAME_TYPES = new Set(["hello", "op", "ephemeral"])
export const MAX_NAME_BYTES = 128
export const MAX_MESSAGE_BYTES = 64 * 1024
const KINDS = ["snapshot", "diff", "presence", "ephemeral"]

function byteLength(s) {
  return new TextEncoder().encode(s).length
}

function validName(v) {
  return typeof v === "string" && v !== "" && byteLength(v) <= MAX_NAME_BYTES
}

/** The fixed frame-to-parent schema. Anything else is dropped. */
export function validFrameMessage(data) {
  if (!data || typeof data !== "object" || data.suite !== 1) return false
  if (!FRAME_TYPES.has(data.type)) return false

  let json
  try {
    json = JSON.stringify(data)
  } catch (_e) {
    return false
  }
  if (typeof json !== "string" || byteLength(json) > MAX_MESSAGE_BYTES) return false

  if (data.type === "hello") return true
  if (data.type === "ephemeral") return validName(data.channel)

  if (!validName(String(data.req ?? "x"))) return false
  const op = data.op
  if (!op || typeof op !== "object" || !OP_TYPES.has(op.type)) return false
  return op.type.startsWith("state.") ? validName(op.key) : validName(op.name)
}

function win() {
  return typeof window !== "undefined" ? window : globalThis
}

export default {
  mounted() {
    this.canvasId = this.el.dataset.canvasId
    this.nodeId = this.el.dataset.nodeId
    this.hookId = this.el.id
    this.iframe = null

    this.onMessage = (event) => this.handleFrameMessage(event)
    this.onLoad = () => this.join()
    win().addEventListener("message", this.onMessage)

    const prefix = `canvas_room:${this.canvasId}:${this.nodeId}:`
    for (const kind of KINDS) {
      this.handleEvent(prefix + kind, (payload) =>
        this.toFrame({ ...payload, suite: 1, type: kind }),
      )
    }

    this.bindIframe()
  },

  updated() {
    this.bindIframe()
  },

  destroyed() {
    win().removeEventListener("message", this.onMessage)
    if (this.iframe) this.iframe.removeEventListener("load", this.onLoad)
    this.iframe = null
    this.pushEvent("canvas_room_leave", this.ids())
  },

  bindIframe() {
    const iframe = this.el.querySelector("iframe")
    if (iframe === this.iframe) return
    if (this.iframe) this.iframe.removeEventListener("load", this.onLoad)
    this.iframe = iframe
    if (iframe) iframe.addEventListener("load", this.onLoad)
  },

  ids() {
    return { canvas_id: this.canvasId, node_id: this.nodeId, hook_id: this.hookId }
  },

  join() {
    this.pushEvent("canvas_room_join", this.ids(), (reply) => {
      if (reply && reply.ok) {
        const { ok: _ok, ...snapshot } = reply
        this.toFrame({ ...snapshot, suite: 1, type: "snapshot", connected: true })
      } else {
        this.toFrame({
          suite: 1,
          type: "snapshot",
          connected: false,
          error: (reply && reply.error) || "unavailable",
        })
      }
    })
  },

  handleFrameMessage(event) {
    if (!this.iframe || event.source !== this.iframe.contentWindow) return
    const data = event.data
    if (!validFrameMessage(data)) return

    if (data.type === "hello") {
      this.join()
    } else if (data.type === "op") {
      this.pushEvent("canvas_room_op", { ...this.ids(), op: data.op }, (reply) =>
        this.toFrame({ ...(reply || { ok: false, error: "error" }), suite: 1, type: "ack", req: data.req }),
      )
    } else if (data.type === "ephemeral") {
      this.pushEvent("canvas_room_ephemeral", {
        ...this.ids(),
        channel: data.channel,
        payload: data.payload ?? null,
      })
    }
  },

  toFrame(msg) {
    const target = this.iframe && this.iframe.contentWindow
    if (target) target.postMessage(msg, "*")
  },
}
