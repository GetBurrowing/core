// ChatDock (task 01a15f2e stage 3).
//
// `#chat-dock` wraps the streaming replies, the jump-to-latest anchor, the
// typing indicator and the composer. Below lg on a routed chat it is an
// absolute glass overlay (`.chat-dock--glass`) and the timeline runs UNDER
// it, so the timeline's end padding has to follow the dock's height: the
// composer grows as you type, the typing and streaming rows come and go, and
// the bar hiding on focus changes the dock's bottom gap.
//
// This hook measures the dock's border box and writes it as `--chat-dock-h`
// on `document.documentElement`. Not on #chat-dock or #chat-drop-zone:
// LiveView's patch rewrites the attributes of server-rendered elements, so an
// inline style there can be stripped by the next patch. <html> sits outside
// every LiveView container.
//
// Where the dock is `display: contents` (desktop, embedded chat) it has no
// box, so the variable is removed and the CSS fallback is unused anyway.
//
// It NEVER writes `scrollTop`. `ScrollToBottom` owns the pin and its own
// observed position; a foreign write can read as a user scroll and raise the
// jump chip. So on every height change it dispatches `chat:dock-resized` on
// window and ScrollToBottom's listener runs its existing pin-if-at-bottom
// path (`scrollToBottom(preDistance)`).
//
// The @mention list (redesign rung 10, stage 3) is NOT clearance. It opens in
// flow inside the dock and grows it upward over the conversation, which must
// not move: `_measure` subtracts the list's height, so opening, filtering and
// closing the list writes no new `--chat-dock-h` (nor `--phone-chrome-bottom`,
// which is built on it) and dispatches no `chat:dock-resized`.
import { watchKeyboard } from "../lib/keyboard_inset.js"

// The soft keyboard (2026-10-23): `watchKeyboard` sets `data-keyboard-open`
// and `--keyboard-inset` on <html> while it is up, and app.css drops the
// dock's tab-bar and safe-area clearance to an 8px gap above the keyboard.
// See lib/keyboard_inset.js for why focus alone could not.
export const MENTION_LIST_SELECTOR = '[data-role="mention-list"]'
export const DOCK_VAR = "--chat-dock-h"
export const DOCK_EVENT = "chat:dock-resized"

const ChatDock = {
  mounted() {
    this._height = null
    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(() => this._measure())
      this._observer.observe(this.el, { box: "border-box" })
    }
    this._measure()
    this._unwatchKeyboard = watchKeyboard()
  },

  updated() {
    this._measure()
  },

  destroyed() {
    if (this._unwatchKeyboard) {
      this._unwatchKeyboard()
      this._unwatchKeyboard = null
    }
    if (this._observer) {
      this._observer.disconnect()
      this._observer = null
    }
    document.documentElement.style.removeProperty(DOCK_VAR)
    this._height = null
  },

  _measure() {
    const root = document.documentElement
    if (getComputedStyle(this.el).display === "contents") {
      root.style.removeProperty(DOCK_VAR)
      this._height = null
      return
    }
    const height = Math.round((this.el.getBoundingClientRect().height - this._listHeight()) * 100) / 100
    if (height === this._height) return
    const previous = this._height
    this._height = height
    root.style.setProperty(DOCK_VAR, `${height}px`)
    const delta = previous === null ? 0 : height - previous
    window.dispatchEvent(new CustomEvent(DOCK_EVENT, { detail: { height, delta } }))
  },

  _listHeight() {
    const list =
      typeof this.el.querySelector === "function" ? this.el.querySelector(MENTION_LIST_SELECTOR) : null
    return list ? list.getBoundingClientRect().height : 0
  },
}

export default ChatDock
