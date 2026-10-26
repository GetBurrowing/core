#!/usr/bin/env node
// Deterministic echo runtime for task 01a174f5 stage 3's e2e cases.
//
// Connects every runtime in the seed's credentials file
// (seed-reply-inline-fixture.sh) to the review server's /runtime/ws socket
// and joins `runtime:<runtime_id>`. On every "attention" push that carries a
// chat message it replies on THAT runtime with
//
//   { space_id, content: "<agent name> echo: <message.content>",
//     in_reply_to_message_id: signal.message_id }
//
// so the answer exercises stage 1's federated placement (a reply to a thread
// message posts into that thread, anything else top-level). When the content
// contains "[wait 6]" it waits 6 seconds first, sending `typing` while it
// waits. No LLM, no randomness, no dependencies (Node 22+ global WebSocket).
//
// Usage:
//   node e2e/scripts/echo-runtime.mjs --url http://localhost:<port> [--creds <file>]
//
// --creds defaults to $TMPDIR/reply-inline-e2e-runtimes.json. Tokens are read
// from that file and never logged.

import { readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`)
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

const baseUrl = arg("url", process.env.REPLY_INLINE_URL)
if (!baseUrl) {
  console.error("echo-runtime: --url http://localhost:<port> is required")
  process.exit(2)
}
const credsPath = arg("creds", join(process.env.TMPDIR || tmpdir(), "reply-inline-e2e-runtimes.json"))
const creds = JSON.parse(readFileSync(credsPath, "utf8"))
const WAIT_MARK = "[wait 6]"
const WAIT_MS = 6000

const log = (...parts) => console.log(new Date().toISOString(), ...parts)

function connect(rt) {
  const wsBase = baseUrl.replace(/^http/, "ws").replace(/\/$/, "")
  const qs = new URLSearchParams({ vsn: "2.0.0", runtime_id: rt.runtime_id, token: rt.token })
  const ws = new WebSocket(`${wsBase}/runtime/ws/websocket?${qs}`)
  const topic = `runtime:${rt.runtime_id}`
  let ref = 0
  let joinRef = null
  let heartbeat = null
  // space id -> "[wait 6]" answers still pending on this runtime
  const waiting = new Map()
  const nextRef = () => String(++ref)
  const send = (event, payload, jr = joinRef) => ws.send(JSON.stringify([jr, nextRef(), topic, event, payload]))

  ws.addEventListener("open", () => {
    joinRef = nextRef()
    ws.send(
      JSON.stringify([joinRef, joinRef, topic, "phx_join", { client_info: { product: "reply-inline-echo", version: "1" } }]),
    )
    heartbeat = setInterval(() => ws.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}])), 25000)
  })

  ws.addEventListener("message", (ev) => {
    let frame
    try {
      frame = JSON.parse(ev.data)
    } catch {
      return
    }
    const [, msgRef, , event, payload] = frame
    if (event === "phx_reply" && msgRef === joinRef) {
      log(`${rt.name}: join ${payload.status} on ${topic}`)
      return
    }
    if (event === "phx_reply" && payload?.status === "error") {
      log(`${rt.name}: push refused`, JSON.stringify(payload.response))
      return
    }
    if (event !== "attention") return

    const signal = payload?.signal || {}
    const message = payload?.message
    const spaceId = signal.space_id
    if (!message || !spaceId) return

    const content = String(message.content ?? "")
    const reply = () => {
      send("reply", {
        space_id: spaceId,
        content: `${rt.name} echo: ${content}`,
        in_reply_to_message_id: signal.message_id,
      })
      log(`${rt.name}: echoed message ${signal.message_id} (reason ${signal.reason})`)
      // The server clears this agent's typing indicator on every reply, so
      // while another "[wait 6]" answer is still pending, say so again.
      if ((waiting.get(spaceId) || 0) > 0) send("typing", { space_id: spaceId, typing: true })
    }

    log(`${rt.name}: attention ${signal.reason} for message ${signal.message_id}`)
    if (content.includes(WAIT_MARK)) {
      waiting.set(spaceId, (waiting.get(spaceId) || 0) + 1)
      send("typing", { space_id: spaceId, typing: true })
      setTimeout(() => {
        waiting.set(spaceId, waiting.get(spaceId) - 1)
        reply()
      }, WAIT_MS)
    } else {
      reply()
    }
  })

  ws.addEventListener("close", () => {
    clearInterval(heartbeat)
    log(`${rt.name}: socket closed; reconnecting in 2s`)
    setTimeout(() => connect(rt), 2000)
  })

  ws.addEventListener("error", () => {
    // `close` follows and reconnects.
  })
}

for (const rt of creds.runtimes) connect(rt)
log(`echo-runtime: ${creds.runtimes.length} runtime(s) for /chat/${creds.space_slug} at ${baseUrl}`)
