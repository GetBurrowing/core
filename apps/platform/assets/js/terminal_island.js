// Remote terminal island: a SEPARATE esbuild entry point (the `terminal`
// profile in config/config.exs), never part of js/app.js. xterm.js is large and
// only the terminal page needs it. test/no_xterm_in_app_bundle_test.mjs asserts
// on the built app.js bytes.
//
// Loaded on demand by js/lib/load_terminal.js, which resolves with
// `window.__burrow_terminal`: `{ mount }`.
//
// This file wires the pieces: xterm, the fit addon, a Phoenix socket to
// /terminal/ws, and TerminalSession (js/terminal/session.js). It does not touch
// what the terminal prints: output goes straight to xterm.

import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"
import { Socket } from "phoenix"
import { supportsX25519 } from "./terminal/crypto.js"
import { THEME } from "./terminal/palette.js"
import { TerminalSession, toArrayBuffer } from "./terminal/session.js"
import { KEY_BYTES, applyCtrl } from "./terminal/keys.js"
import { needsConfirm, confirmText } from "./terminal/paste.js"

const FONT = '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace'

/** A Phoenix channel as the session's adapter. One socket per attempt, so a token is never reused. */
function phoenixConnect(runtimeId, token) {
  const socket = new Socket("/terminal/ws", { params: { token }, reconnectAfterMs: () => 1e9 })
  socket.connect()
  const channel = socket.channel("terminal_view:" + runtimeId, {})
  let closeCb = () => {}
  channel.onClose(() => closeCb())
  channel.onError(() => closeCb())
  socket.onError(() => closeCb())
  return {
    on: (event, cb) => channel.on(event, cb),
    onClose: (cb) => (closeCb = cb),
    join: () =>
      new Promise((resolve, reject) => {
        channel
          .join()
          .receive("ok", resolve)
          .receive("error", (e) => reject(e ?? {}))
          .receive("timeout", () => reject({ reason: "timeout" }))
      }),
    push: (event, payload) =>
      new Promise((resolve, reject) => {
        channel.push(event, toArrayBuffer(payload)).receive("ok", resolve).receive("error", reject).receive("timeout", reject)
        // `in`, `hello`, `resize` and `detach` carry no reply; do not wait.
        if (event !== "mode") resolve()
      }),
    leave: () => {
      channel.leave()
      socket.disconnect()
    },
  }
}

function confirmPaste(host, text) {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog")
    dialog.className = "rounded-xl border border-edge bg-base-100 p-5 text-base-content backdrop:bg-black/50"
    const msg = document.createElement("p")
    msg.className = "text-sm"
    msg.textContent = confirmText(text)
    const row = document.createElement("div")
    row.className = "mt-4 flex justify-end gap-2"
    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.textContent = "Cancel"
    cancel.className = "rounded-md border border-edge px-3 py-1.5 text-sm text-base-content"
    const ok = document.createElement("button")
    ok.type = "button"
    ok.textContent = "Paste"
    ok.className = "rounded-md bg-primary px-3 py-1.5 text-sm text-primary-content"
    const done = (value) => {
      dialog.close()
      dialog.remove()
      resolve(value)
    }
    cancel.addEventListener("click", () => done(false))
    ok.addEventListener("click", () => done(true))
    dialog.addEventListener("cancel", (e) => {
      e.preventDefault()
      done(false)
    })
    row.append(cancel, ok)
    dialog.append(msg, row)
    host.append(dialog)
    dialog.showModal()
    ok.focus()
  })
}

/**
 * Mount the terminal. `ctx`: { root, host, runtimeId, pushEvent(event, payload, cb), handleEvent(event, cb) }.
 * Returns { destroy }.
 */
async function mount(ctx) {
  const { root, host, runtimeId } = ctx
  const state = (s, reason) => ctx.pushEvent("terminal_state", { state: s, reason })

  if (!(await supportsX25519())) {
    // Never fall back to plaintext.
    state("unsupported")
    return { destroy() {} }
  }

  const phone = window.matchMedia("(max-width: 1023px)")
  const term = new Terminal({
    theme: THEME,
    fontFamily: FONT,
    fontSize: phone.matches ? 13 : 14,
    lineHeight: 1.2,
    letterSpacing: 0,
    cursorStyle: "block",
    cursorBlink: false,
    allowProposedApi: false,
    disableStdin: true,
    scrollback: 5000,
  })
  const fit = new FitAddon()
  term.loadAddon(fit)
  term.open(host)
  const refit = () => {
    try {
      fit.fit()
    } catch {
      /* hidden or zero-sized */
    }
  }
  refit()

  let ctrl = false
  const session = new TerminalSession({
    getToken: () =>
      new Promise((resolve) => ctx.pushEvent("terminal_token", {}, (reply) => resolve(reply?.token ?? null))),
    connect: (token) => phoenixConnect(runtimeId, token),
    term: {
      // The session sees only these four. There is deliberately no clear or reset.
      write: (bytes) => term.write(bytes),
      setInputEnabled: (on) => (term.options.disableStdin = !on),
      setDimmed: (dim) => host.setAttribute("data-dimmed", String(dim)),
    },
    onState: state,
    onCwd: (cwd) => ctx.pushEvent("terminal_cwd", { cwd }),
    onMode: (mode) => ctx.pushEvent("terminal_mode", { mode }),
  })

  const enc = new TextEncoder()
  const sendText = (text) => session.send(enc.encode(ctrl ? applyCtrl(text) : text)).then(() => (ctrl = false))
  term.onData((text) => sendText(text))
  term.onResize(({ cols, rows }) => session.resize(cols, rows))
  session.resize(term.cols, term.rows)

  // Multi-line paste: acts on the user's clipboard text before it is sent.
  const onPaste = (e) => {
    const text = e.clipboardData?.getData("text") ?? ""
    if (session.mode === "rw" && needsConfirm(text)) {
      e.preventDefault()
      e.stopPropagation()
      confirmPaste(root, text).then((yes) => yes && term.paste(text))
    }
  }
  host.addEventListener("paste", onPaste, true)

  // Phone key row (rendered by the LiveView in Can type only).
  const onKey = (e) => {
    const btn = e.target.closest?.("[data-terminal-key]")
    if (!btn) return
    const key = btn.getAttribute("data-terminal-key")
    if (key === "ctrl") {
      ctrl = !ctrl
      btn.setAttribute("aria-pressed", String(ctrl))
    } else if (KEY_BYTES[key]) {
      session.send(enc.encode(KEY_BYTES[key]))
    }
    term.focus()
  }
  root.addEventListener("click", onKey)

  ctx.handleEvent("terminal:set_mode", async ({ mode }) => {
    const ok = await session.setMode(mode)
    if (ok && mode === "rw") term.focus()
  })

  const observer = new ResizeObserver(refit)
  observer.observe(host)

  session.start()

  return {
    destroy() {
      observer.disconnect()
      host.removeEventListener("paste", onPaste, true)
      root.removeEventListener("click", onKey)
      session.detach()
      term.dispose()
    },
  }
}

const api = Object.freeze({ mount })
window.__burrow_terminal = api
export default api
